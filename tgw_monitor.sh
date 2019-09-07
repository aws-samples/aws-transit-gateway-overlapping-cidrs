#!/bin/bash

EC2_AVAIL_ZONE=`curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone`
EC2_REGION="`echo \"$EC2_AVAIL_ZONE\" | sed 's/[a-z]$//'`"
EC2_URL="https://ec2.$EC2_REGION.amazonaws.com"
MY_INSTANCE_ID=`/usr/bin/curl --silent http://169.254.169.254/latest/meta-data/instance-id`
INTERFACE=`/usr/bin/curl --silent  http://169.254.169.254/latest/meta-data/network/interfaces/macs/`
SUBNET_ID=`/usr/bin/curl --silent http://169.254.169.254/latest/meta-data/network/interfaces/macs/$INTERFACE/subnet-id`
MY_RT=`aws ec2 describe-route-tables --query "RouteTables[*].Associations[?SubnetId=='$SUBNET_ID'].RouteTableId" --region $EC2_REGION --output text`
VPC_ID=`/usr/bin/curl --silent http://169.254.169.254/latest/meta-data/network/interfaces/macs/$INTERFACE/vpc-id`

declare -A rtIp
declare -A tcIp
declare -a vpcIp
declare -a natIp
declare -a vpcRt

`tc qdisc add dev eth0 root handle 1: htb > /dev/null 2>&1`
`tc qdisc add dev eth0 ingress > /dev/null 2>&1`

function tc_ip()
{

PRIMARY_NAT=`aws ec2 describe-instances --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=NATPrimary" --query "Reservations[*].Instances[*].InstanceId" --region $EC2_REGION --output text`
SECONDARY_NAT=`aws ec2 describe-instances --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=NATSecondary" --query "Reservations[*].Instances[*].InstanceId" --region $EC2_REGION --output text`

   # eval string into a new associative array
    eval "declare -A func_rtIp="${1#*=}

vpcIp=( $(tc -p filter show dev eth0 | awk '{for (i=1;i<=NF;i++) if ($i == "src") {print $(i+1)};}' | sed 's/^0*//') )
natIp=( $(tc -p filter show dev eth0 root | awk '{for (i=1;i<=NF;i++) if ($i == "dst") {print $(i+1)};}' | sed 's/^0*//') )
for num in "${!vpcIp[@]}" "${!natIp[@]}"; do tcIp["${vpcIp[$num]}"]=${natIp[$num]}; done

if [[ -n ${!tcIp[*]} ]]; then 
    echo `date` "---- We have filters in tc. Checking if we need to delete any filters" 
    counter=${#tcIp[@]} 
    for m in "${!tcIp[@]}"; do  # $m is VPC IP and tcIp  is NAT IP
        if [ "${tcIp[$m]}" != "${func_rtIp[$m]}" ]; then
               
         # Remove filters
          #Ingress
          echo `date` "---- Removing Ingress filter with VPC IP $m and NAT IP ${tcIp[$m]}" 
          tempHandleVpcIp=`sipcalc $m | grep -e "Host address" |awk '{for (i=1;i<=NF;i++) if ($i == "-") {print $(i+1)};}' | head -1`
          tempHandleIngress="$(tc -p filter show dev eth0 root | grep -B 2 $tempHandleVpcIp | grep -B 1 "${tcIp[$m]}" | awk -F'800::' '{print $2}' | awk {'print $1}' | tr -d '\040\011\012\015')"
           `tc filter del dev eth0 parent ffff: protocol ip prio 1 handle 800::$tempHandleIngress u32`
           if [ $PRIMARY_NAT == $MY_INSTANCE_ID ]; then
            `aws ec2 delete-route --route-table-id $MY_RT --destination-cidr-block ${tcIp[$m]} --region $EC2_REGION`
            echo `date` "---- Removed Route ${tcIp[$m]} from route table $MY_RT" 
           fi
           
           #Egress
            echo `date` "---- Removing Egress filter with VPC IP $m and NAT IP ${tcIp[$m]}" 
            tempHandleNatIp=`sipcalc ${tcIp[$m]} | grep -e "Host address" |awk '{for (i=1;i<=NF;i++) if ($i == "-") {print $(i+1)};}' | head -1`
            tempHandleEgress="$(tc -p filter show dev eth0 | grep -B 2 $tempHandleNatIp | grep -B 1 "$m" | awk -F'800::' '{print $2}' | awk {'print $1}' | tr -d '\040\011\012\015')"
             `tc filter del dev eth0 parent 1: protocol ip prio 1 handle 800::$tempHandleEgress u32` 
             if [ $PRIMARY_NAT == $MY_INSTANCE_ID ]; then
             `aws ec2 delete-route --route-table-id $MY_RT --destination-cidr-block $m --region $EC2_REGION`
             echo `date` "---- Removed Route $m from route table $MY_RT"
             fi

           elif [ "${tcIp[$m]}"=="${func_rtIp[$m]}" ]; then 
                echo `date` "---- Checked tc filters. We have VPC IP $m and NAT IP ${tcIp[$m]} filters in tc. Not taking any actions" 
        fi 
    done
fi

 # If key/value pair of func_rtIp doesn't match with tcIps key value - Add tc filter

for k in "${!func_rtIp[@]}"; do 

    if [[ -z ${!tcIp[*]} && -n ${!func_rtIp[*]} ]]; then 
        echo `date` "---- Adding VPC IP $k and NAT IP ${func_rtIp[$k]} filter "
        `tc filter add dev eth0 parent ffff: protocol ip prio 1 u32 match ip dst ${func_rtIp[$k]} action nat ingress ${func_rtIp[$k]} $k` 
        `tc filter add dev eth0 parent 1: protocol ip prio 1 u32 match ip src $k action nat egress $k ${func_rtIp[$k]}`
        
        # Add route table entries
        if [ $PRIMARY_NAT == $MY_INSTANCE_ID ]; then
             `aws ec2 replace-route --route-table-id $MY_RT --destination-cidr-block ${func_rtIp[$k]} --instance-id $MY_INSTANCE_ID --region $EC2_REGION > /dev/null 2>&1`
                if [ "$?" != "0" ]; then
                 `aws ec2 create-route --route-table-id $MY_RT --destination-cidr-block ${func_rtIp[$k]} --instance-id $MY_INSTANCE_ID --region $EC2_REGION  > /dev/null 2>&1`
                fi
                echo  `date` "---- Route table $MY_RT has been updated with NAT IP ${func_rtIp[$k]} and gateway $MY_INSTANCE_ID "

              `aws ec2 replace-route --route-table-id $MY_RT --destination-cidr-block $k --gateway-id $TGW_ID --region $EC2_REGION > /dev/null 2>&1`
                if [ "$?" != "0" ]; then
                 `aws ec2 create-route --route-table-id $MY_RT --destination-cidr-block $k --gateway-id $TGW_ID --region $EC2_REGION  > /dev/null 2>&1`
                 fi
                echo  `date` "---- Route table $MY_RT has been updated with VPC IP $k and gateway $TGW_ID "
        fi

        # TC config has been updated 
        echo  `date` "---- tc config has been updated with VPC IP $k and NAT IP ${func_rtIp[$k]} " 
        

    elif [ "${func_rtIp[$k]}" != "${tcIp[$k]}" ]; then
        # Add new filter
        `tc filter add dev eth0 parent ffff: protocol ip prio 1 u32 match ip dst ${func_rtIp[$k]} action nat ingress ${func_rtIp[$k]} $k`
        `tc filter add dev eth0 parent 1: protocol ip prio 1 u32 match ip src $k action nat egress $k ${func_rtIp[$k]}`
        
        #Add route table entries
        if [ $PRIMARY_NAT == $MY_INSTANCE_ID ]; then

                 `aws ec2 replace-route --route-table-id $MY_RT --destination-cidr-block ${func_rtIp[$k]} --instance-id $MY_INSTANCE_ID --region $EC2_REGION > /dev/null 2>&1`
                if [ "$?" != "0" ]; then
                `aws ec2 create-route --route-table-id $MY_RT --destination-cidr-block ${func_rtIp[$k]} --instance-id $MY_INSTANCE_ID --region $EC2_REGION  > /dev/null 2>&1`
                fi
                echo  `date` "---- Route table $MY_RT has been updated with NAT IP ${func_rtIp[$k]} and gateway $MY_INSTANCE_ID " 

                 `aws ec2 replace-route --route-table-id $MY_RT --destination-cidr-block $k --gateway-id $TGW_ID --region $EC2_REGION > /dev/null 2>&1`
                 if [ "$?" != "0" ]; then
                 `aws ec2 create-route --route-table-id $MY_RT --destination-cidr-block $k --gateway-id $TGW_ID --region $EC2_REGION  > /dev/null 2>&1`
                 fi
                 echo  `date` "---- Route table $MY_RT has been updated with VPC IP $k and gateway $TGW_ID "
        fi

        # Updated TC with the new values
        echo `date` "---- Filter VPC IP $k and NAT IP ${func_rtIp[$k]} added to tc"
    elif [ "${func_rtIp[$k]}" == "${tcIp[$k]}" ]; then 
       echo `date` "---- We have VPC IP $k and NAT IP ${func_rtIp[$k]} filters in tc. Not taking any actions"
    fi
done

 echo `date` "---- tc filters and TGW Tags are in sync"
}

while [ . ]; do
 i=0
 TGW_ID=`aws ec2 describe-transit-gateway-attachments --filter "Name=resource-id,Values=$VPC_ID" --query "TransitGatewayAttachments[*].TransitGatewayId" --region $EC2_REGION --output text`
 TGW_AttachID=`aws ec2 describe-transit-gateway-attachments --filter "Name=resource-id,Values=$VPC_ID" --query "TransitGatewayAttachments[*].TransitGatewayAttachmentId" --region $EC2_REGION --output text`
 TGW_RT=`aws ec2 describe-transit-gateway-attachments --filter "Name=resource-id,Values=$VPC_ID" --query "TransitGatewayAttachments[*].Association.TransitGatewayRouteTableId" --region $EC2_REGION --output text`

 echo `date` "---- Started Monitoring for any changes in TGW Route Table. Looking for Tags. Key = VPC IP and Value = NATed IP"
 while [ . ]; do
        if [ -z "$TGW_AttachID" ]; then
         echo  `date` "---- VPC is not attached to TGW. Please attach VPC to TGW" 
         break
        fi
        VPC_IP=`aws ec2 describe-transit-gateway-route-tables --transit-gateway-route-table-ids $TGW_RT --query "TransitGatewayRouteTables[*].Tags[$i].Key" --region $EC2_REGION --output text`
        NAT_IP=`aws ec2 describe-transit-gateway-route-tables --transit-gateway-route-table-ids $TGW_RT --query "TransitGatewayRouteTables[*].Tags[$i].Value" --region $EC2_REGION --output text`

        if  [[ (-z $VPC_IP && -z $NAT_IP) && $i == 0 ]] ; then ## if key and value and 0 and this is 1st loop
                echo `date` "---- No VPC IP/Key or NATed IP/Value found. Deleting all tc filters ...."
                `tc filter del dev eth0 parent ffff:`
                `tc filter del dev eth0 parent 1:`
               break
        elif [[ -z $VPC_IP || -z $NAT_IP ]]; then # reached end of tags 
               echo `date` "---- Reached end of TGW Route Table Tags"
              break
        else
            if [[ `sipcalc $VPC_IP | grep "Host address"` && `sipcalc $NAT_IP | grep "Host address"` ]] ; then
            echo `date` "---- Valid IPs VPC IP $VPC_IP and NAT IP $NAT_IP found in the tags. Checking further..."
            rtIp[$VPC_IP]="$NAT_IP"
            fi
        fi
   i=$[$i+1]
  done
        if [ -z "${!rtIp[*]}" ]; then
    echo `date` "---- No Tags found"
    `tc filter del dev eth0 parent ffff:`
    `tc filter del dev eth0 parent 1:`
    echo `date` "---- All tc filters deleted"
      PRIMARY_NAT=`aws ec2 describe-instances --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=NATPrimary" --query "Reservations[*].Instances[*].InstanceId" --region $EC2_REGION --output text`
       if [ $PRIMARY_NAT == $MY_INSTANCE_ID ]; then
        vpcRt=( $(aws ec2 describe-route-tables  --route-table-ids $MY_RT  --query "RouteTables[*].Routes[*].[DestinationCidrBlock]" --region $EC2_REGION --output text) )
         for route in ${!vpcRt[@]}; do
           if [ "${vpcRt[$route]}" != "0.0.0.0/0" ]; then
           `aws ec2 delete-route --route-table-id $MY_RT --destination-cidr-block ${vpcRt[$route]} --region $EC2_REGION > /dev/null 2>&1`
                if [ "$?" == "0" ]; then
                 echo `date` "---- Route ${vpcRt[$route]} deleted from the route table $MY_RT"
                fi
           fi
         done
      fi
    else
         tc_ip "$(declare -p rtIp)"
    fi
    echo `date` "---- Script will resume in another 60 seconds"
    rtIp=()
    tcIp=()
    func_rtIp=()
    vpcIp=()
    natIp=()
    vpcRt=()
    sleep 60
done