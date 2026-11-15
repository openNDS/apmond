/*
 * apmond wifidetect: this node's Wi-Fi chipset and capabilities (libapmon wifidetect.c),
 * detected once at startup and again on request (ubus wifidetect {"refresh": true},
 * apmond wifidetect), never per report. The result is cached here and written to
 * /tmp/apmond/wifidetect for scripts. It is not part of the report protocol.
 * SPDX-License-Identifier: GPL-2.0-only
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "apmond.h"

static char *cached;

/* Write through a temporary file, so a reader never sees half a file */
int apmond_wifidetect_write(const char *json)
{
	const char *tmp = APMOND_WIFIDETECT_FILE ".tmp";
	FILE *f;

	mkdir(APMOND_RUN_DIR, 0755);
	f = fopen(tmp, "w");
	if (f == NULL) {
		return -1;
	}
	fputs(json, f);
	if (fclose(f) != 0) {
		remove(tmp);
		return -1;
	}
	if (rename(tmp, APMOND_WIFIDETECT_FILE) != 0) {
		remove(tmp);
		return -1;
	}
	return 0;
}

/* Detect again; the previous result stays cached if this fails */
int apmond_wifidetect_refresh(void)
{
	uint64_t start = apmon_monotonic_ms();
	char *json = apmon_wifidetect(apmond.id_str);

	if (json == NULL) {
		LOG_ERR_("wifidetect: out of memory");
		return -1;
	}
	free(cached);
	cached = json;
	if (apmond_wifidetect_write(cached) != 0) {
		LOG_INFO_("wifidetect: cannot write %s", APMOND_WIFIDETECT_FILE);
	}
	LOG_INFO_("wifidetect: done in %llu ms", (unsigned long long)(apmon_monotonic_ms() - start));
	return 0;
}

/* The cached JSON, detecting first if there is none yet; NULL on failure */
const char *apmond_wifidetect_json(void)
{
	if (cached == NULL) {
		apmond_wifidetect_refresh();
	}
	return cached;
}
