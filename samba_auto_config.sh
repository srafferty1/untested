#!/bin/bash


group="g-local-nms-samba"
share_dir="/data/csv_sources/nms_share"
localuser="nms-admin"
localuser_password="Password12345!"

#Check if the user is root
if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root. Please run with sudo."
  exit 1
fi

# Ensure the local user exists, if not create the user and set the password
if ! id "$localuser" &>/dev/null; then
  echo "The local user $localuser does not exist. Creating the user..."
  useradd -m "$localuser"
  if [ $? -ne 0 ]; then
    echo "Failed to create the local user $localuser."
    exit 1
  fi

  echo "$localuser:$localuser_password" | chpasswd
  if [ $? -ne 0 ]; then
    echo "Failed to set the password for the local user $localuser."
    exit 1
  fi

  # Add the local user to Samba using the password variable
  echo -e "$localuser_password\n$localuser_password" | smbpasswd -s -a "$localuser"
fi

#Detect current realm
realm=$(realm list | grep 'realm-name' | awk '{print $2}')

if [ -z "$realm" ]; then
  echo "No realm detected. Please join the domain first."
  exit 1
fi

#Extract the workgroup (NetBIOS name) from the realm
workgroup=$(echo $realm | cut -d. -f1 | tr '[:lower:]' '[:upper:]')

echo "Detected realm: $realm"
echo "Setting workgroup (NetBIOS name) to: $workgroup"

#Check if the AD group exists
if ! getent group $group &> /dev/null; then
  echo "The group $group does not exist in the AD. Please create the group or check your configuration."
  exit 1
fi

#Function to check and install package if necessary
check_and_install() {
  package=$1
  if ! rpm -q $package &> /dev/null; then
    echo "$package is not installed. Installing..."
    if ! yum install -y $package; then
      echo "Failed to install $package. Please check your repository configuration."
      exit 1
    fi
  else
    echo "$package is already installed."
  fi
}

#Check and install necessary packages
for package in samba samba-client samba-common; do
  check_and_install $package
done

#Create the directory if it doesn't exist
if [ ! -d "$share_dir" ]; then
  mkdir -p $share_dir
fi

# Properly format the group name for setfacl
realm_group="${realm^^}\\${group^^}"
realm_group_escaped=$(echo "$realm_group" | sed 's/\\/\\\\/g')

echo "Formatted and escaped realm group: $realm_group_escaped"

# Ensure the directory has the correct permissions for both the AD group and the local user
chown -R "$localuser:$localuser" "$share_dir"
chmod -R 0775 "$share_dir"

# Apply ACLs and debug
{
  setfacl -R -m g:"$realm_group_escaped":rwx "$share_dir" &&
  setfacl -R -m u:"$localuser":rwx "$share_dir" &&
  setfacl -R -m d:g:"$realm_group_escaped":rwx "$share_dir" &&
  setfacl -R -m d:u:"$localuser":rwx "$share_dir"
} || {
  echo "Failed to set ACL. Debugging information:"
  echo "Group: $realm_group_escaped"
  echo "Directory: $share_dir"
  exit 1
}

#Verify the settings
ls -ld $share_dir
getfacl $share_dir

#Backup existing smb.conf and clear old configuration
cp /etc/samba/smb.conf /etc/samba/smb.conf.bak
cat /dev/null > /etc/samba/smb.conf

#Configure Samba for AD integration
cat <<EOL >> /etc/samba/smb.conf
[global]
   workgroup = $workgroup
   security = ads
   realm = $realm
   log file = /var/log/samba/%m.log
   log level = 1
   load printers = no
   disable spoolss = yes
   bind interfaces only = yes
   interfaces = lo eth0
   
   idmap config * : backend = tdb
   idmap config * : range = 3000-7999
   idmap config $workgroup : backend = rid
   idmap config $workgroup : range = 10000-99999
   
   template shell = /bin/bash

[$(basename $share_dir)]
   path = $share_dir
   valid users = @"$realm\\$group", $localuser
   read only = no
   browsable = yes
   writable = yes
   create mask = 0775
   directory mask = 0775
EOL

#Restart Samba services
systemctl restart smb
systemctl enable smb

#Check if Samba service started successfully
if ! systemctl is-active --quiet smb; then
  echo "Samba service failed to start. Check the service status and logs for more information."
  systemctl status smb
  journalctl -xe
  exit 1
fi

#Set SELinux permissions (if SELinux is enabled and enforcing)
if sestatus | grep "SELinux status" | grep -q "enabled"; then
  chcon -t samba_share_t $share_dir
fi

#Add Samba service to the firewall
firewall-cmd --permanent --zone=public --add-service=samba
firewall-cmd --reload


echo "Samba configuration is complete. The share is ready to be accessed using AD credentials."

#Output success message
echo "Script execution successful."

exit 0
