#!/bin/bash
#SET TENANCY
export USER=opc
export CNODES=2
export C=$1
export PRE=`uuidgen | cut -c-5`
export subnet=4
export IMAGE=Oracle-Linux-7.5-2018.05.09-1
export ad=2
export region=us-ashburn-1
#export region=eu-frankfurt-1
#export region=us-phoenix-1
#export region=eu-london-1
export INFO='--region '$region' --availability-domain '$AD' -c '$C

export AD=`oci iam availability-domain list -c $C --region $region --output table | grep 'AD-$ad' | awk '{ print $4 }'`
export OS=`oci compute image list -c $C --region $region --output table --query "data [*].{ImageName:\"display-name\", OCID:id}" | grep $IMAGE | awk '{ print $4 }'`

#CREATE NETWORK
echo
echo 'Creating Network'
V=`oci network vcn create --region $region --cidr-block 10.0.$subnet.0/24 --compartment-id $C --display-name "hpc_vcn-$PRE" --wait-for-state AVAILABLE | jq -r '.data.id'`
NG=`oci network internet-gateway create --region $region -c $C --vcn-id $V --is-enabled TRUE --display-name "hpc_ng-$PRE" --wait-for-state AVAILABLE | jq -r '.data.id'`
RT=`oci network route-table create --region $region -c $C --vcn-id $V --display-name "hpc_rt-$PRE" --wait-for-state AVAILABLE --route-rules '[{"cidrBlock":"0.0.0.0/0","networkEntityId":"'$NG'"}]' | jq -r '.data.id'`
SL=`oci network security-list create --region $region -c $C --vcn-id $V --display-name "hpc_sl-$PRE" --wait-for-state AVAILABLE --egress-security-rules '[{"destination":  "0.0.0.0/0",  "protocol": "all", "isStateless":  null}]' --ingress-security-rules '[{"source":  "0.0.0.0/0",  "protocol": "all", "isStateless":  null}]' | jq -r '.data.id'`
S=`oci network subnet create -c $C --vcn-id $V --region $region --availability-domain "$AD" --display-name "hpc_subnet-$PRE" --cidr-block "10.0.$subnet.0/26" --route-table-id $RT --security-list-ids '["'$SL'"]' --wait-for-state AVAILABLE | jq -r '.data.id'`

#CREATE FILE SYSTEM
#echo
#echo 'Creating File System'
#FSS=`oci fs file-system create --region $region --availability-domain "$AD" -c $C --display-name "HPC_File_System" --wait-for-state ACTIVE | jq -r '.data.id'`
#MT=`oci fs mount-target create --region $region --availability-domain "$AD" -c $C --subnet-id $S --display-name "mountTarget$PRE" --wait-for-state ACTIVE --ip-address 10.0.0.20 | jq -r '.data.id'`

#CREATE BLOCK
BV=`oci bv volume create $INFO --display-name "hpc_block-$PRE" --size-in-gbs 4096 --wait-for-state AVAILABLE | jq -r '.data.id'`

#CREATE HEADNODE
echo
echo 'Creating Headnode'
masterID=`oci compute instance launch $INFO --shape "BM.Standard1.36" --display-name "hpc_master-$PRE" --image-id $OS --subnet-id $S --private-ip 10.0.$subnet.2 --wait-for-state RUNNING --user-data-file hn_configure.sh --ssh-authorized-keys-file ~/.ssh/id_rsa.pub | jq -r '.data.id'`
oci compute volume-attachment attach $INFO --instance-id $masterID --type iscsi --volume-id $BV --wait-for-state ATTACHED 

#CREATE COMPUTE
echo
echo 'Creating Compute Nodes'
computeData=$(for i in `seq 1 $CNODES`; do oci compute instance launch $INFO --shape "BM.Standard1.36" --display-name "hpc_cn_$i-$PRE" --image-id $OS --subnet-id $S --assign-public-ip true  --user-data-file hn_configure.sh --ssh-authorized-keys-file ~/.ssh/id_rsa.pub; done)

#LIST IP's
echo
echo 'Created Headnode and Compute Nodes'
echo 'Waiting five minutes for IP addresses'
sleep 300

masterIP=$(oci compute instance list-vnics --region $region --instance-id $masterID | jq -r '.data[]."public-ip"')
for iid in `oci compute instance list --region $region -c $C | jq -r '.data[] | select(."lifecycle-state"=="RUNNING") | .id'`; do newip=`oci compute instance list-vnics --region $region --instance-id $iid | jq -r '.data[0] | ."display-name"+": "+."private-ip"+", "+."public-ip"'`; echo $iid, $newip; done
scp -o StrictHostKeyChecking=no ~/.ssh/id_rsa $USER@$masterIP:~/.ssh/

#CREATE REMOVE SCRIPT
cat << EOF >> removeCluster-$PRE.sh
#!/bin/bash
export masterIP=$masterIP
export USER=$USER
export C=$1
export PRE=$PRE
export region=$region
export AD=$AD
export V=$V
export NG=$NG
export RT=$RT
export SL=$SL
export S=$S
export masterID=$masterID


#DELETE INSTANCES
echo Removing: Head Node
oci compute instance terminate --region $region --instance-id $masterID --force

EOF
cat << "EOF" >> removeCluster-$PRE.sh
echo Removing: Compute Nodes
for instanceid in $(oci compute instance list --region $region -c $C | jq -r '.data[] | select(."display-name" | contains ("'$PRE'")) | .id'); do oci compute instance terminate --region $region --instance-id $instanceid --force; done
sleep 30
echo Removing: Subnet, Route Table, Security List, Gateway, and VCN
oci network subnet delete --region $region --subnet-id $S --force
sleep 10
oci network route-table delete --region $region --rt-id $RT --force
sleep 10
oci network security-list delete --region $region --security-list-id $SL --force
sleep 10
oci network internet-gateway delete --region $region --ig-id $NG --force
sleep 10
oci network vcn delete --region $region --vcn-id $V --force
echo Complete
EOF

chmod +x removeCluster-$PRE.sh
