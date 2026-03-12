#!/bin/bash
# HELIOS DC Healthcheck
# Checks if Samba AD DC is responding to LDAP queries

samba-tool domain level show > /dev/null 2>&1
exit $?
