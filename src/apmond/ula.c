/*
 * apmond ULA addresses, ported from apmond 1.x (manage_ula / claim_router_ula):
 * - prefix and subnet derived from the passphrase (apmon_ula_prefix), so every node computes them
 * - every node: <prefix>:<subnet>:<EUI-64 of the device MAC>/64 on option device
 * - the collector: <prefix>:<subnet>::1/64, first come wins:
 *     not a collector candidate      -> never hold ::1 (peer)
 *     holding ::1 and DAD failed     -> drop it, back off
 *     ::1 answers (another collector) -> back off
 *     backed off and ::1 silent for router_takeover_misses checks -> take over
 *     first claim after a random 0..claim_delay_max s delay, then wait for DAD
 * - addresses are added and removed with rtnetlink (no ip command); all are removed on stop
 * - with neither option netdev nor option interface set, a sender puts its node ULA on the device
 *   that reaches the collector (apmond_ula_follow_uplink), eg br-wan on a node whose uplink
 *   network is bridged into its WAN, such as a CPE
 * SPDX-License-Identifier: GPL-2.0-only
 */
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/netlink.h>
#include <linux/rtnetlink.h>
#include <net/if.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include "apmond.h"

#define IFA_TENTATIVE 0x40
#define IFA_DADFAILED 0x08

static struct in6_addr node_addr;
static struct in6_addr router_addr;
static int have_prefix;
static int added_node;
static int added_router;
static int misses;
static int claim_delay_done;
static int backed_off;
static int listen_blocked;

/* ---------- rtnetlink address add/delete ---------- */

static int addr_change(int add, const struct in6_addr *addr, int ifindex)
{
	struct {
		struct nlmsghdr nh;
		struct ifaddrmsg ifa;
		char attrs[64];
	} req;
	struct rtattr *rta;
	struct sockaddr_nl sa;
	char reply[1024];
	struct nlmsghdr *nh;
	int fd;
	int ret = -1;
	ssize_t n;

	memset(&req, 0, sizeof(req));
	req.nh.nlmsg_len = NLMSG_LENGTH(sizeof(struct ifaddrmsg));
	req.nh.nlmsg_flags = NLM_F_REQUEST | NLM_F_ACK;
	if (add) {
		req.nh.nlmsg_type = RTM_NEWADDR;
		req.nh.nlmsg_flags |= NLM_F_CREATE | NLM_F_EXCL;
	} else {
		req.nh.nlmsg_type = RTM_DELADDR;
	}
	req.ifa.ifa_family = AF_INET6;
	req.ifa.ifa_prefixlen = 64;
	req.ifa.ifa_index = (unsigned int)ifindex;

	rta = (struct rtattr *)((char *)&req + NLMSG_ALIGN(req.nh.nlmsg_len));
	rta->rta_type = IFA_LOCAL;
	rta->rta_len = RTA_LENGTH(sizeof(*addr));
	memcpy(RTA_DATA(rta), addr, sizeof(*addr));
	req.nh.nlmsg_len = NLMSG_ALIGN(req.nh.nlmsg_len) + RTA_ALIGN(rta->rta_len);

	fd = socket(AF_NETLINK, SOCK_RAW | SOCK_CLOEXEC, NETLINK_ROUTE);
	if (fd < 0) {
		return -1;
	}
	memset(&sa, 0, sizeof(sa));
	sa.nl_family = AF_NETLINK;

	if (sendto(fd, &req, req.nh.nlmsg_len, 0, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
		close(fd);
		return -1;
	}

	n = recv(fd, reply, sizeof(reply), 0);
	if (n > 0) {
		nh = (struct nlmsghdr *)reply;
		if (nh->nlmsg_type == NLMSG_ERROR) {
			struct nlmsgerr *err = NLMSG_DATA(nh);

			if (err->error == 0) {
				ret = 0;
			} else if (add && err->error == -EEXIST) {
				ret = 0;
			}
		}
	}
	close(fd);
	return ret;
}

/*
 * Look the address up in /proc/net/if_inet6.
 * Returns -1 if absent, else the kernel's address flags (tentative 0x40, dadfailed 0x08).
 */
static int addr_flags(const struct in6_addr *addr)
{
	FILE *f = fopen("/proc/net/if_inet6", "r");
	char want[33];
	char line[256];
	int flags = -1;

	if (f == NULL) {
		return -1;
	}
	apmon_hex_encode(addr->s6_addr, 16, want);

	while (fgets(line, sizeof(line), f) != NULL) {
		char hex[33];
		unsigned int ifindex;
		unsigned int plen;
		unsigned int scope;
		unsigned int fl;
		char name[IFNAMSIZ + 1];

		if (sscanf(line, "%32s %x %x %x %x %16s", hex, &ifindex, &plen, &scope, &fl, name) != 6) {
			continue;
		}
		if (strcmp(hex, want) == 0 && strcmp(name, apmond.cfg.netdev) == 0) {
			flags = (int)fl;
			break;
		}
	}
	fclose(f);
	return flags;
}

static void addr_text(const struct in6_addr *addr, char *out, size_t len)
{
	inet_ntop(AF_INET6, addr, out, (socklen_t)len);
}

/* quiet = routine DAD re-check: log at debug level, not notice */
static int add_address_q(const struct in6_addr *addr, int quiet)
{
	char text[INET6_ADDRSTRLEN];
	int ifindex = (int)if_nametoindex(apmond.cfg.netdev);

	addr_text(addr, text, sizeof(text));
	if (ifindex == 0) {
		LOG_ERR_("device [ %s ] not found, cannot assign ULA addresses", apmond.cfg.netdev);
		return -1;
	}
	if (addr_flags(addr) >= 0) {
		return 0;
	}
	if (addr_change(1, addr, ifindex) != 0) {
		LOG_ERR_("failed to add ULA address %s/64 to %s", text, apmond.cfg.netdev);
		return -1;
	}
	if (quiet) {
		LOG_DEBUG_("ULA address %s/64 re-added to %s for the DAD re-check", text, apmond.cfg.netdev);
	} else {
		LOG_NOTICE_("ULA address %s/64 added to %s", text, apmond.cfg.netdev);
	}
	return 0;
}

static int add_address(const struct in6_addr *addr)
{
	return add_address_q(addr, 0);
}

static void del_address_q(const struct in6_addr *addr, int quiet)
{
	char text[INET6_ADDRSTRLEN];
	int ifindex = (int)if_nametoindex(apmond.cfg.netdev);

	if (ifindex == 0 || addr_flags(addr) < 0) {
		return;
	}
	addr_text(addr, text, sizeof(text));
	if (addr_change(0, addr, ifindex) == 0) {
		if (quiet) {
			LOG_DEBUG_("ULA address %s/64 deleted from %s for the DAD re-check", text, apmond.cfg.netdev);
		} else {
			LOG_NOTICE_("ULA address %s/64 deleted from %s", text, apmond.cfg.netdev);
		}
	}
}

static void del_address(const struct in6_addr *addr)
{
	del_address_q(addr, 0);
}

/* Is another collector answering on <ula>::1? (1.x pinged it; a TCP connect to our port says the same) */
static int router_answers(void)
{
	struct sockaddr_in6 sa;
	struct pollfd pfd;
	int fd;
	int answered = 0;

	fd = socket(AF_INET6, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
	if (fd < 0) {
		return 0;
	}
	memset(&sa, 0, sizeof(sa));
	sa.sin6_family = AF_INET6;
	sa.sin6_port = htons((uint16_t)apmond.cfg.port);
	sa.sin6_addr = router_addr;

	if (connect(fd, (struct sockaddr *)&sa, sizeof(sa)) == 0) {
		answered = 1;
	} else if (errno == EINPROGRESS) {
		pfd.fd = fd;
		pfd.events = POLLOUT;
		if (poll(&pfd, 1, 1000) == 1) {
			int err = 0;
			socklen_t len = sizeof(err);

			getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len);
			/* refused also means something holds the address, but not apmond: treat as in use */
			if (err == 0 || err == ECONNREFUSED) {
				answered = 1;
			}
		}
	}
	close(fd);
	return answered;
}

/* ---------- public ---------- */

int apmond_ula_init(const char *passphrase)
{
	uint8_t prefix[8];
	uint8_t iid[8];

	if (apmon_ula_prefix(passphrase, prefix) != 0) {
		return -1;
	}
	apmon_eui64_iid(apmond.id, iid);

	memset(&router_addr, 0, sizeof(router_addr));
	memcpy(router_addr.s6_addr, prefix, 8);
	router_addr.s6_addr[15] = 1;

	memcpy(node_addr.s6_addr, prefix, 8);
	memcpy(node_addr.s6_addr + 8, iid, 8);

	addr_text(&node_addr, apmond.node_ula, sizeof(apmond.node_ula));
	addr_text(&router_addr, apmond.router_ula, sizeof(apmond.router_ula));
	have_prefix = 1;
	return 0;
}

static void set_reason(const char *fmt, const char *arg)
{
	char reason[sizeof(apmond.role_reason)];

	snprintf(reason, sizeof(reason), fmt, arg);
	if (strcmp(reason, apmond.role_reason) != 0) {
		snprintf(apmond.role_reason, sizeof(apmond.role_reason), "%s", reason);
		LOG_NOTICE_("%s", reason);
	}
}

static int recheck_cycles;

static int drop_router(const char *fmt)
{
	del_address(&router_addr);
	added_router = 0;
	misses = 0;
	backed_off = 1;
	claim_delay_done = 0;
	set_reason(fmt, apmond.router_ula);
	return 0;
}

/*
 * The collector listener failed while this node held ::1 (r25, r26): holding ::1 without a
 * listener makes peers see ECONNREFUSED, which router_answers() treats as in use, so nobody
 * would collect. Give up ::1 through the DAD-conflict path and stay a sender until a listener
 * probe succeeds again (apmond_ula_set_listen_ok), so a broken node never re-enters the race.
 */
void apmond_ula_give_up_router(void)
{
	listen_blocked = 1;
	if (!have_prefix) {
		return;
	}
	drop_router("backed off: collector listener failed, %s given up");
}

/* Listen before claim (r26): the caller probes the listener before each claim attempt */
void apmond_ula_set_listen_ok(int ok)
{
	if (ok) {
		listen_blocked = 0;
	} else {
		listen_blocked = 1;
	}
}

/*
 * Two collectors can both hold ::1: claims at the same moment, or a node that took over while
 * the real collector was away and kept it when it came back (DAD only runs when an address is
 * added). So the holder deletes and adds ::1 again every collector_recheck cycles: if another
 * node holds it, DAD fails here and this node backs off. Returns 1 if this node still holds it.
 * The routine delete/add is logged at debug level; a conflict is logged at notice by drop_router().
 * Linux only runs DAD when an address is added (an NLM_F_REPLACE update of an existing address
 * does not restart it), so the delete cannot be avoided without raw NS probes (CAP_NET_RAW).
 */
static int dad_recheck(void)
{
	int flags;
	int i;

	LOG_DEBUG_("DAD re-check of %s", apmond.router_ula);
	del_address_q(&router_addr, 1);
	if (add_address_q(&router_addr, 1) != 0) {
		return 0;
	}
	for (i = 0; i < 3; i++) {
		flags = addr_flags(&router_addr);
		if (flags < 0 || (flags & IFA_TENTATIVE) == 0 || (flags & IFA_DADFAILED) != 0) {
			break;
		}
		sleep(1);
	}
	flags = addr_flags(&router_addr);
	if (flags < 0 || (flags & IFA_DADFAILED) != 0) {
		return 0;
	}
	return 1;
}

/*
 * Called every interval. candidate = this node may be the collector (upstream gateway or role collector).
 * Returns 1 if this node holds <ula>::1 (is the collector), 0 otherwise.
 */
int apmond_ula_tick(int candidate)
{
	int flags;
	int i;

	if (!have_prefix) {
		return candidate;
	}

	if (add_address(&node_addr) == 0) {
		added_node = 1;
	}

	if (!candidate) {
		misses = 0;
		backed_off = 0;
		claim_delay_done = 0;
		if (addr_flags(&router_addr) >= 0) {
			del_address(&router_addr);
			added_router = 0;
		}
		set_reason("peer: no upstream gateway%s", "");
		return 0;
	}

	flags = addr_flags(&router_addr);
	if (flags >= 0) {
		if (flags & IFA_DADFAILED) {
			return drop_router("DAD failed on %s after claiming - another collector holds it");
		}
		if (apmon_recheck_due(&recheck_cycles, apmond.cfg.collector_recheck)) {
			if (!dad_recheck()) {
				return drop_router("DAD re-check on %s failed - another collector holds it");
			}
		}
		misses = 0;
		backed_off = 0;
		set_reason("collector: upstream gateway detected and %s claimed", apmond.router_ula);
		return 1;
	}

	if (listen_blocked) {
		misses = 0;
		backed_off = 1;
		claim_delay_done = 0;
		set_reason("sender: collector listener cannot open, not claiming %s", apmond.router_ula);
		return 0;
	}

	if (router_answers()) {
		misses = 0;
		backed_off = 1;
		claim_delay_done = 0;
		set_reason("backed off: %s is already in use by another collector", apmond.router_ula);
		return 0;
	}

	if (backed_off) {
		misses++;
		if (misses < apmond.cfg.router_takeover_misses) {
			LOG_INFO_("%s not answering (%d/%d), waiting before takeover", apmond.router_ula, misses,
				  apmond.cfg.router_takeover_misses);
			return 0;
		}
		LOG_NOTICE_("%s not answering for %d checks, taking over", apmond.router_ula, misses);
	}

	if (!claim_delay_done) {
		uint32_t r = 0;

		claim_delay_done = 1;
		apmon_random(&r, sizeof(r));
		if (apmond.cfg.claim_delay_max > 0) {
			sleep(r % (uint32_t)(apmond.cfg.claim_delay_max + 1));
		}
		if (router_answers()) {
			backed_off = 1;
			claim_delay_done = 0;
			set_reason("backed off: %s claimed by another collector during the startup delay", apmond.router_ula);
			return 0;
		}
	}

	if (add_address(&router_addr) != 0) {
		backed_off = 1;
		claim_delay_done = 0;
		set_reason("backed off: failed to add %s", apmond.router_ula);
		return 0;
	}
	added_router = 1;

	/* wait for DAD (default one probe, 1 s) */
	for (i = 0; i < 3; i++) {
		flags = addr_flags(&router_addr);
		if (flags < 0 || (flags & IFA_TENTATIVE) == 0 || (flags & IFA_DADFAILED) != 0) {
			break;
		}
		sleep(1);
	}

	flags = addr_flags(&router_addr);
	if (flags >= 0 && (flags & IFA_DADFAILED)) {
		return drop_router("DAD failed on %s - another collector holds it");
	}

	misses = 0;
	backed_off = 0;
	set_reason("collector: upstream gateway detected and %s claimed", apmond.router_ula);
	return 1;
}

int apmond_ula_holding_router(void)
{
	int flags;

	if (!have_prefix) {
		return 0;
	}
	flags = addr_flags(&router_addr);
	return flags >= 0 && (flags & (IFA_DADFAILED | IFA_TENTATIVE)) == 0;
}

/* Our node ULA is present and past DAD, so it can be used as a source address */
int apmond_ula_node_ready(void)
{
	int flags;

	if (!have_prefix) {
		return 0;
	}
	flags = addr_flags(&node_addr);
	return flags >= 0 && (flags & (IFA_DADFAILED | IFA_TENTATIVE)) == 0;
}

/* ---------- which device a sender uses (option netdev / interface not set) ---------- */

/*
 * The device on which <prefix>::/64 is on-link, from an rtnetlink route dump: a unicast route
 * without a gateway that netifd, an RA or the admin added. Routes the kernel adds for our own
 * addresses (proto kernel) are skipped, as are unreachable routes (eg on lo) and the local table.
 * The current netdev wins if it is one of several. Returns 0 and the name, else -1.
 */
static int prefix_route_dev(char *out, size_t len)
{
	struct {
		struct nlmsghdr nh;
		struct rtmsg rt;
	} req;
	struct sockaddr_nl sa;
	char buf[8192];
	int fd;
	int found = -1;
	int done = 0;

	fd = socket(AF_NETLINK, SOCK_RAW | SOCK_CLOEXEC, NETLINK_ROUTE);
	if (fd < 0) {
		return -1;
	}
	memset(&req, 0, sizeof(req));
	req.nh.nlmsg_len = NLMSG_LENGTH(sizeof(struct rtmsg));
	req.nh.nlmsg_type = RTM_GETROUTE;
	req.nh.nlmsg_flags = NLM_F_REQUEST | NLM_F_DUMP;
	req.rt.rtm_family = AF_INET6;
	memset(&sa, 0, sizeof(sa));
	sa.nl_family = AF_NETLINK;
	if (sendto(fd, &req, req.nh.nlmsg_len, 0, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
		close(fd);
		return -1;
	}

	while (!done) {
		struct nlmsghdr *nh;
		ssize_t got = recv(fd, buf, sizeof(buf), 0);
		int left;

		if (got <= 0) {
			break;
		}
		left = (int)got;
		for (nh = (struct nlmsghdr *)buf; NLMSG_OK(nh, left); nh = NLMSG_NEXT(nh, left)) {
			struct rtmsg *rt = NLMSG_DATA(nh);
			struct rtattr *rta;
			int rlen;
			int oif = 0;
			int gateway = 0;
			int match = 0;
			char name[IF_NAMESIZE];

			if (nh->nlmsg_type == NLMSG_DONE || nh->nlmsg_type == NLMSG_ERROR) {
				done = 1;
				break;
			}
			if (nh->nlmsg_type != RTM_NEWROUTE || rt->rtm_type != RTN_UNICAST || rt->rtm_dst_len != 64 ||
			    rt->rtm_protocol == RTPROT_KERNEL || rt->rtm_table == RT_TABLE_LOCAL) {
				continue;
			}
			rlen = (int)RTM_PAYLOAD(nh);
			for (rta = RTM_RTA(rt); RTA_OK(rta, rlen); rta = RTA_NEXT(rta, rlen)) {
				if (rta->rta_type == RTA_DST && RTA_PAYLOAD(rta) == 16) {
					match = memcmp(RTA_DATA(rta), router_addr.s6_addr, 8) == 0;
				} else if (rta->rta_type == RTA_OIF) {
					oif = *(int *)RTA_DATA(rta);
				} else if (rta->rta_type == RTA_GATEWAY) {
					gateway = 1;
				}
			}
			if (!match || gateway || oif == 0 || if_indextoname((unsigned int)oif, name) == NULL ||
			    strcmp(name, "lo") == 0) {
				continue;
			}
			if (found != 0 || strcmp(name, apmond.cfg.netdev) == 0) {
				snprintf(out, len, "%s", name);
				found = 0;
			}
		}
	}
	close(fd);
	return found;
}

/*
 * Option netdev and option interface not set: a sender uses the device that reaches the
 * collector, so its node ULA and reported addresses are reachable from there:
 *   1. the device on which the apmond ULA prefix is on-link (prefix_route_dev)
 *   2. else the device of the IPv4 default route
 *   3. else the lan device (lan_netdev), as before
 * A collector candidate always uses the lan device. Called every interval, so a WAN that comes
 * up later is picked up; on a change the node ULA (and ::1, if held) moves to the new device.
 */
void apmond_ula_follow_uplink(int candidate)
{
	char dev[sizeof(apmond.cfg.netdev)] = "";
	char gateway[64];
	const char *how = "lan";
	int old;

	if (!apmond.cfg.netdev_auto || apmond.lan_netdev[0] == '\0') {
		return;
	}
	if (candidate) {
		snprintf(dev, sizeof(dev), "%s", apmond.lan_netdev);
	} else if (have_prefix && prefix_route_dev(dev, sizeof(dev)) == 0) {
		how = "ULA prefix route";
	} else if (apmond_default_route(dev, sizeof(dev), gateway, sizeof(gateway)) == 0) {
		how = "IPv4 default route";
	} else {
		snprintf(dev, sizeof(dev), "%s", apmond.lan_netdev);
	}
	if (dev[0] == '\0' || if_nametoindex(dev) == 0 || strcmp(dev, apmond.cfg.netdev) == 0) {
		return;
	}

	old = (int)if_nametoindex(apmond.cfg.netdev);
	if (have_prefix && old != 0) {
		if (addr_flags(&router_addr) >= 0) {
			addr_change(0, &router_addr, old);
		}
		if (addr_flags(&node_addr) >= 0) {
			addr_change(0, &node_addr, old);
		}
	}
	added_router = 0;
	added_node = 0;
	LOG_NOTICE_("network device [ %s ] -> [ %s ] (%s), node ULA %s moves with it", apmond.cfg.netdev, dev, how,
		    apmond.node_ula);
	snprintf(apmond.cfg.netdev, sizeof(apmond.cfg.netdev), "%s", dev);
}

void apmond_ula_cleanup(void)
{
	if (!have_prefix) {
		return;
	}
	if (added_router || addr_flags(&router_addr) >= 0) {
		del_address(&router_addr);
	}
	if (added_node || addr_flags(&node_addr) >= 0) {
		del_address(&node_addr);
	}
	added_router = 0;
	added_node = 0;
}
