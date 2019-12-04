FROM ubuntu:18.04
LABEL maintainer "Tsutomu Nakamura<tsuna.0x00@gmail.com>"

ENV LC_ALL=C.UTF-8
ENV LANG=C.UTF-8

RUN apt-get update && \
    apt-get full-upgrade -y && \
    DEBIAN_FRONTEND=noninteractive apt-get -y install slapd ldap-utils libnss-ldap samba smbldap-tools && \
    DEBIAN_FRONTEND=noninteractive apt-get -y install acl attr autoconf bison build-essential \
        debhelper dnsutils docbook-xml docbook-xsl flex gdb krb5-user \
        libacl1-dev libaio-dev libattr1-dev libblkid-dev libbsd-dev \
        libcap-dev libcups2-dev libgnutls28-dev libjson-perl \
        libldap2-dev libncurses5-dev libpam0g-dev libparse-yapp-perl \
        libpopt-dev libreadline-dev perl perl-modules pkg-config \
        python-all-dev python-dev python-dnspython python-crypto \
        xsltproc zlib1g-dev supervisor iproute2 && \
    apt-get clean

COPY samba.ldif.gz /
COPY entrypoint.sh /opt
RUN chmod u+x /opt/entrypoint.sh
ENTRYPOINT ["/opt/entrypoint.sh"]

