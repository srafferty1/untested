#!/bin/bash

group="g-local-nms-samba"
share_dir="/data/csv_sources/nms_share"

#Check if the user is root
if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root. Please run with sudo."
  exit 1
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

#Ensure the directory has the correct permissions for the AD group
chown -R :"$realm\\$group" $share_dir
chmod -R 0775 $share_dir
setfacl -R -m g:"$realm\\$group":rwx $share_dir
setfacl -R -m d:g:"$realm\\$group":rwx $share_dir

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

[mecm]
   path = $share_dir
   valid users = @"$realm\\$group"
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
