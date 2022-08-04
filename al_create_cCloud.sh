#!/bin/bash
#VER 2.0 - ADD CSTOR
# REMOVED INCLUDE FILE
#VER 3.0 - Optional cStor, 
#        - 1 or 2 interfaces (mgmt, traffic) 

set -e
set -u
set -o pipefail
set -x

{ # whole script in this block to redirect everything also to logfile

azure_cclearv_resource_id=/subscriptions/52ba377e-6215-48d9-beee-b3553fd81150/resourceGroups/CLOUD-BUILDS/providers/Microsoft.Compute/galleries/releases/images/cclear-v/versions/21.4.1
azure_cvuv_resource_id=/subscriptions/52ba377e-6215-48d9-beee-b3553fd81150/resourceGroups/CLOUD-BUILDS/providers/Microsoft.Compute/galleries/releases/images/cvu-v/versions/21.4.1
azure_cstorv_resource_id=/subscriptions/52ba377e-6215-48d9-beee-b3553fd81150/resourceGroups/CLOUD-BUILDS/providers/Microsoft.Compute/galleries/releases/images/cstor-v/versions/21.4.1


debug=0

#====== Customer Network Information
MySubscription="93004638-8c6b-4e33-ba58-946afd57efdf" # Customer Subscription 
MyLocation="eastus2"                                  # Customer Location
MyResourceGroup="alessandro-tf-rg"                       # RG of the VNET where cCloud will be deployed
MyVnet="al-spoke1"                             # VNET where cCloud will be deployed 

#====== TARGET CCLOUD DEPLOYMENT PARAMETERS
cPacketPrefix="al-spoke1"                         # Prefix of the Resource Group and all children
cPacketResourceGroup="alessandro-spoke1-rg"            # Target Resource Group
cPacketMgmtSubnet="al-cpacket-monitoring"             # Subnet where cCloud mgmt will be deployed
cPacketTrafficSubnet="al-cpacket-traffic"       # Subnet where cCloud traffic will flow 
sshPublicKey="$HOME/.ssh/ccloud.pub"                  # ssh key
ToolIP="10.10.10.10"                                  # Target Tool IP if any
numOfCvu=3
numOfcStor=0
twoInterfaces=0
#======

cat >ccloud-settings.ini <<EOF
azure_cclearv_resource_id=$azure_cclearv_resource_id
azure_cvuv_resource_id=$azure_cvuv_resource_id
azure_cstorv_resource_id=$azure_cstorv_resource_id
EOF

          
#======

#CHECK if MGMT subnet exists 
cPacketMgmtSubnet=$(az network vnet subnet show -g $MyResourceGroup --vnet-name $MyVnet --name $cPacketMgmtSubnet --query id -o tsv)

if [[ $twoInterfaces -eq "1" ]]; then 
    #CHECK if TRAFFIC subnet exists 
    #two nics  we use the mgmt and traffic subnet
    cPacketTrafficSubnet=$(az network vnet subnet show -g $MyResourceGroup --vnet-name $MyVnet --name $cPacketTrafficSubnet --query id -o tsv) ;
fi

az group create -l $MyLocation -n $cPacketResourceGroup

# Names of cClear resources 
cClearName=$cPacketPrefix-cClear
cClearMgmtNic=$cClearName-nic

az network nic create -g $cPacketResourceGroup \
    --subnet $cPacketMgmtSubnet \
    --name $cClearMgmtNic \
    --subscription $MySubscription \
    --location $MyLocation 
    #   --private-ip-address 10.10.10.10

./ccloud az cclearv \
    --nic $cClearMgmtNic \
    --ssh-public-key $sshPublicKey \
    --name $cClearName \
    --image $azure_cclearv_resource_id \
    -g $cPacketResourceGroup



#DEPLOY CSTOR
cStorIP=""
if [[ $numOfcStor -eq "1" ]]; then 
    cStorName=$cPacketPrefix-cStor
    cStorMgmtNic=$cStorName-nic
    cStorCaptureNic=$cStorName-capture-nic

    az network nic create -g $cPacketResourceGroup \
        --subnet $cPacketMgmtSubnet \
        --name $cStorMgmtNic \
        --subscription $MySubscription \
        --location $MyLocation 
#   --private-ip-address 11.11.11.11

    if [[ $twoInterfaces -eq "1" ]]; then  
        az network nic create -g $cPacketResourceGroup \
            --subnet $cPacketTrafficSubnet \
            --name $cStorCaptureNic \
            --subscription $MySubscription \
            --location $MyLocation 

        ./ccloud az cstorv \
            --name "$cStorName" \
            --image "$azure_cstorv_resource_id" \
            --resource-group "$cPacketResourceGroup" \
            --management-nic "$cStorMgmtNic" \
            --capture-nic "$cStorCaptureNic" \
            --ssh-public-key $sshPublicKey

        cStorIP=$(az network nic ip-config show \
            --nic-name "$cStorCaptureNic" \
            -g "$cPacketResourceGroup"\
            --name "ipconfig1" \
            --query  privateIpAddress -o tsv)
    else

        ./ccloud az cstorv \
            --name "$cStorName" \
            --image "$azure_cstorv_resource_id" \
            --resource-group "$cPacketResourceGroup" \
            --nic "$cStorMgmtNic" \
            --ssh-public-key $sshPublicKey

        cStorIP=$(az network nic ip-config show \
            --nic-name "$cStorMgmtNic" \
            -g "$cPacketResourceGroup"\
            --name "ipconfig1" \
            --query  privateIpAddress -o tsv)
    fi
fi


# CREATE CVU NICS and VM

indexLimit=$numOfCvu
cVuNamePrefix=$cPacketPrefix-cvuv
#populate additional-tools variable
if [ -z "$cStorIP" ]; then
    if [ -z "$ToolIP" ]; then
            echo "No TOOL DEFINED"
            exit
    else
            additionalTools="--additional-tool $ToolIP"
    fi
else
    if [ -z $ToolIP ]; then
        additionalTools="--additional-tool $cStorIP"
    else
        additionalTools="--additional-tool $cStorIP \
         --additional-tool $ToolIP"
    fi
fi
echo $additionalTools

for ((index=1; index<=$indexLimit; index++ ))
do 
    echo "Creating cvu NICs"
    cVuName=$cVuNamePrefix-$index
    cVuMgmtNicName=$cVuName-nic
    

    #Create cvu NICs 
    
    if [[ $twoInterfaces -eq "1" ]]; then  
        az network nic create -g $cPacketResourceGroup --subnet $cPacketMgmtSubnet \
            -n $cVuMgmtNicName \
            --subscription $MySubscription 
    
        cVuTrafficNicName=$cVuName-traffic-nic
        az network nic create -g $cPacketResourceGroup --subnet $cPacketTrafficSubnet \
        -n $cVuTrafficNicName \
        --subscription $MySubscription \
        --accelerated-networking true \
        --ip-forwarding true

    #create Cvus
    # additional tools
    
        ./ccloud az cvuv \
            -g $cPacketResourceGroup \
            --name $cVuName \
            --vm-type Standard_D2s_v5 \
            --capture-nic $cVuTrafficNicName \
            --management-nic $cVuMgmtNicName \
            $additionalTools \
            --ssh-public-key $sshPublicKey \
            --image $azure_cvuv_resource_id \
            --vnet $MyVnet \
            --subnet $cPacketMgmtSubnet
    else
        az network nic create -g $cPacketResourceGroup --subnet $cPacketMgmtSubnet \
            -n $cVuMgmtNicName \
            --subscription $MySubscription \
            --accelerated-networking true \
            --ip-forwarding true

        ./ccloud az cvuv \
            -g $cPacketResourceGroup \
            --name $cVuName \
            --vm-type Standard_D2s_v5 \
            --nic $cVuMgmtNicName \
            $additionalTools \
            --ssh-public-key $sshPublicKey \
            --image $azure_cvuv_resource_id \
            --vnet $MyVnet \
            --subnet $cPacketMgmtSubnet
    fi

done

## CVUV LOAD BALANCER

cPacketLbName=$cPacketPrefix-lb

az network lb create -g $cPacketResourceGroup -n $cPacketLbName \
--sku Standard --subnet $cPacketMgmtSubnet \
--frontend-ip-name $cPacketLbName-fe --backend-pool-name $cPacketLbName-be

az network lb probe create \
--resource-group $cPacketResourceGroup \
--lb-name $cPacketLbName \
--name $cPacketLbName-hp \
--interval 5 \
--protocol tcp \
--port 443

az network lb rule create \
--resource-group $cPacketResourceGroup \
--lb-name $cPacketLbName \
--name $cPacketLbName-rule \
--protocol All \
--backend-port 0 \
--frontend-ip-name $cPacketLbName-fe \
--frontend-port 0 \
--backend-pool-name $cPacketLbName-be \
--probe-name $cPacketLbName-hp \
--idle-timeout 4 \
--enable-tcp-reset false

MyLbBePoolId=$(az network lb address-pool show -g $cPacketResourceGroup \
--lb-name $cPacketLbName --name $cPacketLbName-be --query id -o tsv)
    echo $MyLbBePoolId


for (( index=1; index<=$indexLimit; index++ ))
    do
    cVuName=$cVuNamePrefix-$index
    if [[ $twoInterfaces -eq "1" ]]; then  
        cVuTrafficNicName=$cVuName-traffic-nic
    else
        cVuTrafficNicName=$cVuName-nic
    fi
    az network nic ip-config address-pool add \
        --address-pool $MyLbBePoolId \
        --ip-config-name ipconfig1 \
        --nic-name $cVuTrafficNicName \
        --resource-group $cPacketResourceGroup
    done

echo "====================="
echo " DEPLOYMENT COMPLETE"
echo "====================="

} 2>&1 | tee ccloud_script_log.txt
