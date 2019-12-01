#!/bin/bash

main() {
    if [[ ! -f /opt/finished ]]; then
        build_nt
    fi

    exec /usr/bin/supervisord -c /etc/supervisor/supervisord.conf
}

build_nt() {
    /usr/sbin/slapd -h "ldap:/// ldapi:///" -g openldap -u openldap -F /etc/ldap/slapd.d

    local try_count=120
    local count=0
    local result=1

    while [[ $count -lt $try_count ]]; do
        ldapsearch -LLL -Y EXTERNAL -H ldapi:/// -b "cn=config" "(olcDatabase=*)" > /dev/null 2>&1
        result=$?
        [[ $result -eq 0 ]] && break
        sleep 0.5
        (( count++ ))
    done

    [[ $result -ne 0 ]] && {
        echo "ERROR: Failed to launch OpenLDAP" >&2
        return 1
    }

    local passwd="p@ssword0"
    local passwd_crypt=$(slappasswd -s ${passwd})
    local domain="mysite.example.com"
    local domain_component=$(sed -e 's/^/dc=/' -e 's/\./,dc=/g' <<< "$domain")
    local samba_domain="MYSITE"
    local host_name="samba-nt"

    ldapadd -Y EXTERNAL -H ldapi:/// << EOF
dn: olcDatabase={0}config,cn=config
changetype: modify
add: olcRootPW
olcRootPW: ${passwd_crypt}
EOF

    ldapadd -Y EXTERNAL -H ldapi:/// << EOF
dn: olcDatabase={0}config,cn=config
changetype: modify
replace: olcRootDN
olcRootDN: cn=admin,cn=config
EOF

    ldapsearch -LLL -D "cn=admin,cn=config" -w ${passwd} -b "olcDatabase={0}config,cn=config" "(olcDatabase=*)"

    # May duplicate these attributes
    ldapadd -Y EXTERNAL -H ldapi:/// -f /etc/ldap/schema/cosine.ldif > /dev/null 2>&1 || true
    ldapadd -Y EXTERNAL -H ldapi:/// -f /etc/ldap/schema/nis.ldif > /dev/null 2>&1 || true
    ldapadd -Y EXTERNAL -H ldapi:/// -f /etc/ldap/schema/inetorgperson.ldif > /dev/null 2>&1 || true

    # Checking database type.
    ldapsearch -LLL -Y EXTERNAL -H ldapi:/// -D "cn=config" -b "cn=config" 2>/dev/null | egrep 'olcDatabase=\{[0-9]\}(b|h|m)db,cn=config'

    ldapmodify -Y EXTERNAL -H ldapi:/// << EOF
dn: olcDatabase={1}mdb,cn=config
changetype: modify
replace: olcSuffix
olcSuffix: ${domain_component}

dn: olcDatabase={1}mdb,cn=config
changetype: modify
replace: olcRootDN
olcRootDN: cn=Manager,${domain_component}

dn: olcDatabase={1}mdb,cn=config
changetype: modify
replace: olcRootPW
olcRootPW: ${passwd_crypt}
EOF

    ldapadd -x -D "cn=Manager,${domain_component}" -w ${passwd} << EOF
dn: ${domain_component}
objectClass: dcObject
objectClass: organization
dc: mysite
o: Example Inc.
EOF

    local ip=$(getent hosts samba-nt | cut -d ' ' -f 1)
    echo "${ip} samba-nt.${domain}" >> /etc/hosts

    gunzip -c /samba.ldif.gz | ldapadd -Y EXTERNAL -H ldapi:///

    ldapmodify -x -D "cn=admin,cn=config" -w ${passwd} << EOF
dn: olcDatabase={1}mdb,cn=config
changetype: modify
replace: olcDbIndex
olcDbIndex: objectClass eq,pres
olcDbIndex: ou eq,pres,sub
olcDbIndex: cn eq,pres,sub
olcDbIndex: mail eq,pres,sub
olcDbIndex: surname eq,pres,sub
olcDbIndex: givenname eq,pres,sub
olcDbIndex: member pres,eq
olcDbIndex: uidNumber eq,pres
olcDbIndex: gidNumber eq,pres
olcDbIndex: loginShell eq,pres
olcDbIndex: uid eq,pres,sub
olcDbIndex: memberUid eq,pres,sub
olcDbIndex: nisMapName eq,pres,sub
olcDbIndex: nisMapEntry eq,pres,sub

dn: olcDatabase={1}mdb,cn=config
changetype: modify
replace: olcDbIndex
olcDbIndex: uniqueMember eq,pres
olcDbIndex: sambaSID eq
olcDbIndex: sambaPrimaryGroupSID eq
olcDbIndex: sambaGroupType eq
olcDbIndex: sambaSIDList eq
olcDbIndex: sambaDomainName eq
olcDbIndex: default sub
EOF

    cp -ip /etc/samba/smb.conf /etc/samba/smb.conf.org
    cat << EOF > /etc/samba/smb.conf
[global]
        workgroup = ${samba_domain}
        netbios name = LDAP
        server role = auto
        deadtime = 10
        log level = 1
        log file = /var/log/samba/log.%m
        max log size = 5000
        debug pid = yes
        debug uid = yes
        syslog = 3
        utmp = yes
        security = user
        domain logons = yes
        os level = 64
        logon path = 
        logon home = 
        logon drive = 
        logon script = 
        passdb backend = ldapsam:"ldap://${host_name}.${domain}/"
        ldap ssl = off
        ldap admin dn = cn=Manager,${domain_component}
        ldap delete dn = no
        ldap password sync = yes
        ldap suffix = ${domain_component}
        ldap user suffix = ou=Users
        ldap group suffix = ou=Groups
        ldap machine suffix = ou=Computers
        ldap idmap suffix = ou=Idmap
        add user script = /usr/sbin/smbldap-useradd -m '%u' -t 1
        rename user script = /usr/sbin/smbldap-usermod -r '%unew' '%uold'
        delete user script = /usr/sbin/smbldap-userdel '%u'
        set primary group script = /usr/sbin/smbldap-usermod -g '%g' '%u'
        add group script = /usr/sbin/smbldap-groupadd -p '%g'
        delete group script = /usr/sbin/smbldap-groupdel '%g'
        add user to group script = /usr/sbin/smbldap-groupmod -m '%u' '%g'
        delete user from group script = /usr/sbin/smbldap-groupmod -x '%u' '%g'
        add machine script = /usr/sbin/smbldap-useradd -w '%u' -t 1
        nt acl support = yes
        socket options = TCP_NODELAY SO_RCVBUF=8192 SO_SNDBUF=8192 SO_KEEPALIVE
[NETLOGON]
        path = /var/lib/samba/netlogon
        browseable = no
        share modes = no
[PROFILES]
        path = /var/lib/samba/profiles
        browseable = no
        writeable = yes
        create mask = 0611
        directory mask = 0700
        profile acls = yes
        csc policy = disable
        map system = yes
        map hidden = yes
EOF

    cat << EOF > /etc/smbldap-tools/smbldap_bind.conf
masterDN="cn=Manager,${domain_component}"
masterPw="${passwd}"
EOF

    smbpasswd -w ${passwd}

    local smb_sid=$(cut -d ' ' -f 6 <<< "$(net getlocalsid)")
    echo $smb_sid

    cat << EOF > /etc/smbldap-tools/smbldap.conf
SID="${smb_sid}"
sambaDomain="${samba_domain}"
masterLDAP="ldap://${host_name}.${domain}/"
ldapTLS="0"
verify="none"
cafile="/etc/smbldap-tools/ca.pem"
clientcert="/etc/smbldap-tools/smbldap-tools.example.com.pem"
clientkey="/etc/smbldap-tools/smbldap-tools.example.com.key"
suffix="${domain_component}"
usersdn="ou=Users,\${suffix}"
computersdn="ou=Computers,\${suffix}"
groupsdn="ou=Groups,\${suffix}"
idmapdn="ou=Idmap,\${suffix}"
sambaUnixIdPooldn="sambaDomainName=\${sambaDomain},\${suffix}"
scope="sub"
password_hash="SSHA"
password_crypt_salt_format="%s"
userLoginShell="/bin/bash"
userHome="/home/%U"
userHomeDirectoryMode="700"
userGecos="System User"
defaultUserGid="513"
defaultComputerGid="515"
skeletonDir="/etc/skel"
shadowAccount="1"
defaultMaxPasswordAge="45"
userSmbHome="\\PDC-SRV\%U"
userProfile="\\PDC-SRV\profiles\%U"
userHomeDrive="H:"
userScript="logon.bat"
mailDomain="${domain}"
with_smbpasswd="0"
smbpasswd="/usr/bin/smbpasswd"
with_slappasswd="0"
slappasswd="/usr/sbin/slappasswd"
EOF

    echo "#######################################################"
    echo "Running smbldap-populate."
    echo "It will ask you domain root password"
    echo "#######################################################"
    smbldap-populate < <(echo -e "$passwd\n$passwd")

    net groupmap list; echo
    groupadd -g 552 smb_replicators
    groupadd -g 513 smb_domain_users
    groupadd -g 512 smb_domain_admins
    groupadd -g 514 smb_domain_guests
    groupadd -g 544 smb_administrators
    groupadd -g 550 smb_print_operators
    groupadd -g 551 smb_backup_operators
    groupadd -g 515 smb_domain_computers
    groupadd -g 548 smb_account_operators
    net groupmap list

    # Adding test users
    add_test_entries "$passwd" "$domain_component" "saburo-suzuki-pc" "saburo-suzuki"

    cat << EOF > /etc/supervisor/conf.d/supervisord.conf
[supervisord]
nodaemon=true
[program:ldap]
command=/usr/sbin/slapd -h "ldap:/// ldapi:///" -g openldap -u openldap -F /etc/ldap/slapd.d
[program:smbd]
command=/usr/sbin/smbd
[program:nmbd]
command=/usr/sbin/nmbd
EOF

    kill $(pgrep slapd)
    touch /opt/finished


}

add_test_entries() {
    local passwd="$1"
    local domain_component="$2"
    local workstation="$3"
    local user="$4"

    useradd -M -g smb_domain_computers -s /bin/false ${workstation}$
    useradd -M ${user}
    smbldap-useradd -a -G 'Domain Users' -m -s /bin/bash -d /home/${user} -F "" -P ${user} < <(echo -e "${passwd}\n${passwd}")
    smbpasswd -e ${user}

    net sam rights grant ${user} SeMachineAccountPrivilege
    ldapsearch -LLL -w ${passwd} -H ldap://localhost -x -D "uid=${user},ou=Users,${domain_component}" -b "ou=Users,${domain_component}"
    ldapsearch -LLL -w ${passwd} -H ldap://localhost -x -D "uid=root,ou=Users,${domain_component}" -b "ou=Users,${domain_component}"
}

main "$@" || exit 1
exit 0

