#!/bin/bash

# --------------------------------------------------------------------------------------------------------------
# This script looks for free tier autonomous databases instances in an OCI tenant (in home region) 
# and delete them if found
# Note: OCI tenant and region given by an OCI CLI PROFILE
# Author        : Christophe Pauliat
# Platforms     : MacOS / Linux
# prerequisites : jq (JSON parser) installed, OCI CLI 2.6.11+ installed and OCI config file configured with profiles
#
# Versions
#    2019-11-14: Initial Version
#    2020-03-20: change location of temporary files to /tmp + check oci exists
# --------------------------------------------------------------------------------------------------------------

# -------- functions

usage()
{
cat << EOF
Usage: $0 OCI_PROFILE [--confirm]

Notes: 
- OCI_PROFILE must exist in ~/.oci/config file (see example below)
- If --confirm is provided, found compute instances are deleted, otherwise only listed.

[EMEAOSCf]
tenancy     = ocid1.tenancy.oc1..aaaaaaaaw7e6nkszrry6d5hxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
user        = ocid1.user.oc1..aaaaaaaayblfepjieoxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
fingerprint = 19:1d:7b:3a:17:xx:xx:xx:xx:xx:xx:xx:xx:xx:xx:xx
key_file    = /Users/cpauliat/.oci/api_key.pem
region      = eu-frankfurt-1
EOF
  exit 1
}

# -- Get the home region from the profile
get_home_region_from_profile()
{
  oci --profile $PROFILE iam region-subscription list --query "data[].{home:\"is-home-region\",name:\"region-name\"}" | jq -r '.[] |  select(.home == true) | .name'
}

# -- Get list of compartment IDs for active compartments (excluding root)
get_comp_ids()
{
  oci --profile $PROFILE iam compartment list --compartment-id-in-subtree true --all --query "data [?\"lifecycle-state\" == 'ACTIVE']" 2>/dev/null| egrep "^ *\"id"|awk -F'"' '{ print $4 }'
}

cleanup()
{
  rm -f $TMP_FILE
}

trap_ctrl_c()
{
  echo
  echo -e "SCRIPT INTERRUPTED BY USER !"
  echo

  cleanup
  exit 99
}

# -- look for free autonomous databases instances in given compartment
look_for_free_adbs()
{
  local lcompid=$1
  
  #echo "DEBUG: comp $lcompid"

  oci --profile $PROFILE db autonomous-database list -c $lcompid --region $HOME_REGION --all \
       --query "data [?\"is-free-tier\" && \"lifecycle-state\" != 'TERMINATED'].{ADBid:id}" 2>/dev/null | jq -r '.[].ADBid' | \
  while read id
  do  
    if [ $CONFIRM == true ]; then 
      echo "TERMINATING free autonomous database instance $id in compartment $lcompid"
      oci --profile $PROFILE db autonomous-database delete  --autonomous-database-id $id --force > /dev/null 2>&1
    else
      echo "FOUND free autonomous database instance $id in compartment $lcompid but not terminated since --confirm not provided"
    fi
  done
}

# -------- main

OCI_CONFIG_FILE=~/.oci/config
CONFIRM=false
TMP_FILE=/tmp/tmp_$$

case $# in
1) PROFILE=$1
   ;;
2) PROFILE=$1
   if [ "$2" == "--confirm" ]; then CONFIRM=true; else usage; fi
   ;;
*) usage
   ;;
esac

# -- trap ctrl-c and call trap_ctrl_c()
trap trap_ctrl_c INT

# -- Check if oci is installed
which oci > /dev/null 2>&1
if [ $? -ne 0 ]; then echo "ERROR: oci not found !"; exit 2; fi

# -- Check if jq is installed
which jq > /dev/null 2>&1
if [ $? -ne 0 ]; then echo "ERROR: jq not found !"; exit 2; fi

# -- Check if the PROFILE exists
grep "\[$PROFILE\]" $OCI_CONFIG_FILE > /dev/null 2>&1
if [ $? -ne 0 ]; then echo "ERROR: PROFILE $PROFILE does not exist in file $OCI_CONFIG_FILE !"; exit 3; fi

# -- get tenancy OCID from OCI PROFILE (root compartment)
TENANCYOCID=`egrep "^\[|ocid1.tenancy" $OCI_CONFIG_FILE|sed -n -e "/\[$PROFILE\]/,/tenancy/p"|tail -1| awk -F'=' '{ print $2 }' | sed 's/ //g'`

# -- get home region from OCI PROFILE
HOME_REGION=`get_home_region_from_profile`

# -- Check in root compartment
look_for_free_adbs $TENANCYOCID 

# -- Check in all other active compartments
CPT_IDS=`get_comp_ids`
for id in $CPT_IDS
do
  look_for_free_adbs $id
done

# -- end
cleanup
exit 0