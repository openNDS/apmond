#!/bin/sh
# Copyright (C) BlueWave Projects and Services 2015-2026
#
#	This software is released under the GNU General Public License version 2 or any later version.
#	This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation,
#	either version 2 of the License, or (at your option) any later version.
#
#	This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
#	See the GNU General Public License for more details.
#
#	To obtain a copy of the GNU General Public License, see <https://www.gnu.org/licenses/>.
#
# apmond receiver CGI - installed by the apmond package (not generated at runtime)
printf "%s\n\n" "Content-type: text/html"
node_id="$HTTP_USER_AGENT"
querystring="$QUERY_STRING"
status=$(/usr/sbin/apmond write_node_data "$node_id" "$querystring")
echo "$status"
