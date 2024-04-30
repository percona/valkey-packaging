#!/bin/sh
set -e

if [ "${1#-}" != "$1" ] || [ "${1%.conf}" != "$1" ]; then
	set -- valkey-server "$@"
fi

if [ "$1" = 'valkey-server' -a "$(id -u)" = '0' ]; then
	find . \! -user valkey -exec chown valkey '{}' +
	exec gosu valkey "$0" "$@"
fi

um="$(umask)"
if [ "$um" = '0022' ]; then
	umask 0077
fi

exec "$@"
