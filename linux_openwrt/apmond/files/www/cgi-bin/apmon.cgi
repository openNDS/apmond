#!/bin/sh
# apmond receiver CGI - installed by the apmond package (not generated at runtime)
# SPDX-License-Identifier: GPL-2.0-only
printf "%s\n\n" "Content-type: text/html"
node_id="$HTTP_USER_AGENT"
querystring="$QUERY_STRING"
status=$(/usr/sbin/apmond write_node_data "$node_id" "$querystring")
echo "$status"
