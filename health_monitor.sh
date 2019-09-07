#!/bin/bash
# This script will monitor another OTHER instance and take over its routes
# if communication with the other instance fails

# Health Check variables
Num_Pings=3
Ping_Timeout=1
Wait_Between_Pings=2
Wait_for_Instance_Stop=60
Wait_for_Instance_Start=300


EC2_AVAIL_ZONE=`curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone`
EC2_REGION="`echo \"$EC2_AVAIL_ZONE\" | sed 's/[a-z]$//'`"
EC2_URL="https://ec2.$EC2_REGION.amazonaws.com"
MY_INSTANCE_ID=`/usr/bin/curl --silent http://169.254.169.254/latest/meta-data/instance-id`
INTERFACE=`/usr/bin/curl --silent  http://169.254.169.254/latest/meta-data/network/interfaces/macs/`
SUBNET_ID=`/usr/bin/curl --silent http://169.254.169.254/latest/meta-data/network/interfaces/macs/$INTERFACE/subnet-id`
MY_RT=`aws ec2 describe-route-tables --query "RouteTables[*].Associations[?SubnetId=='$SUBNET_ID'].RouteTableId" --region $EC2_REGION --output text`
VPC_ID=`/usr/bin/curl --silent http://169.254.169.254/latest/meta-data/network/interfaces/macs/$INTERFACE/vpc-id`

sleep 60

echo `date` "---- Starting monitor"

PRIMARY_NAT=`aws ec2 describe-instances --region $EC2_REGION --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=NATPrimary" --query "Reservations[*].Instances[*].InstanceId" --output text`
SECONDARY_NAT=`aws ec2 describe-instances --region $EC2_REGION --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=NATSecondary" --query "Reservations[*].Instances[*].InstanceId" --output text`
TGW_RT=`aws ec2 describe-transit-gateway-attachments --filter "Name=resource-id,Values=$VPC_ID" --query "TransitGatewayAttachments[*].Association.TransitGatewayRouteTableId" --region $EC2_REGION --output text`

if [ $PRIMARY_NAT == $MY_INSTANCE_ID ]; then
OTHER_ID=$SECONDARY_NAT
OTHER_IP=`aws ec2 describe-instances --instance-id $OTHER_ID --query 'Reservations[].Instances[].PrivateIpAddress' --region $EC2_REGION --output text`
elif [ $SECONDARY_NAT == $MY_INSTANCE_ID ]; then
OTHER_ID=$PRIMARY_NAT
OTHER_IP=`aws ec2 describe-instances --instance-id $OTHER_ID --query 'Reservations[].Instances[].PrivateIpAddress' --region $EC2_REGION --output text`
fi 

echo `date` "---- Primary NAT instance is $PRIMARY_NAT and Secondary NAT instance is $SECONDARY_NAT"


while [ . ]; do

  # Check health of other OTHER instance
  pingresult=`ping -c $Num_Pings -W $Ping_Timeout $OTHER_IP | grep time= | wc -l`
  # Check to see if any of the health checks succeeded, if not
  if [ "$pingresult" == "0" ]; then
    # Set HEALTHY variables to unhealthy (0)
    ROUTE_HEALTHY=0
    OTHER_HEALTHY=0
    STOPPING_OTHER=0
    while [ "$OTHER_HEALTHY" == "0" ]; do
      # OTHER instance is unhealthy, loop while we try to fix it
      if [ "$ROUTE_HEALTHY" == "0" ] && [ $SECONDARY_NAT == $MY_INSTANCE_ID ]; then
    	echo `date` "---- Primary NAT instance $OTHER_ID heartbeat failed, taking over"
    	vpcRt=( $(aws ec2 describe-route-tables  --route-table-ids $MY_RT --query "RouteTables[*].Routes[*].[DestinationCidrBlock]" --region $EC2_REGION --output text) )
      tgwNAT=( $(aws ec2 describe-transit-gateway-route-tables --transit-gateway-route-table-ids $TGW_RT --query "TransitGatewayRouteTables[*].Tags[*].[Value]" --region $EC2_REGION --output text) )
         for route in ${!tgwNAT[@]}; do
            for prefix in ${!vpcRt[@]}; do
               if [ "${vpcRt[$prefix]}" == "${tgwNAT[$route]}" ]; then
                `aws ec2 replace-route --route-table-id $MY_RT --destination-cidr-block ${vpcRt[$prefix]} --instance-id $MY_INSTANCE_ID --region $EC2_REGION > /dev/null 2>&1`
                 echo `date` "---- Route Table ID $MY_RT with destination IP ${vpcRt[$prefix]} has been updated with $MY_INSTANCE_ID"
               fi
            done
         done
      echo `date` "---- Making $MY_INSTANCE_ID as Primary NAT Instance"
    	 `aws ec2 delete-tags --resources $OTHER_ID --region $EC2_REGION --tags Key=Name,Value=`
       `aws ec2 create-tags --resources $OTHER_ID --tags Key=Name,Value=NATSecondary --region $EC2_REGION`
       `aws ec2 delete-tags --resources $MY_INSTANCE_ID --region $EC2_REGION --tags Key=Name,Value=`
       `aws ec2 create-tags --resources $MY_INSTANCE_ID --tags Key=Name,Value=NATPrimary --region $EC2_REGION`
	    ROUTE_HEALTHY=1
      SECONDARY_NAT=$OTHER_ID
      echo `date` "---- Instance $MY_INSTANCE_ID is now the Primary and instance $OTHER_ID is the Secondary"
      fi
      # Check OTHER state to see if we should stop it or start it again
      OTHER_STATE=`aws ec2 describe-instances --instance-ids $OTHER_ID --region $EC2_REGION --output text --query 'Reservations[*].Instances[*].State.Name'`

      if [ "$OTHER_STATE" == "stopped" ]; then
    	echo `date` "---- Other $OTHER_ID instance stopped, starting it back up"
        `aws ec2 start-instances --instance-ids $OTHER_ID --region $EC2_REGION > /dev/null 2>&1`
	       OTHER_HEALTHY=1
        sleep $Wait_for_Instance_Start
        OTHER_STATE=`aws ec2 describe-instances --instance-ids $OTHER_ID --region $EC2_REGION --output text --query 'Reservations[*].Instances[*].State.Name'`
        echo `date` "---- Other $OTHER_ID instance is $OTHER_STATE now"
        echo `date` "---- Primary NAT Instance is $MY_INSTANCE_ID"
        echo `date` "---- Secondary NAT instance is $OTHER_ID"
       else
         	if [ "$STOPPING_OTHER" == "0" ]; then
         	  echo `date` "---- Other $OTHER_ID instance $OTHER_STATE, attempting to stop for reboot"
	          `aws ec2 stop-instances --instance-ids $OTHER_ID --region $EC2_REGION > /dev/null 2>&1`
	           STOPPING_OTHER=1
	        fi
        sleep $Wait_for_Instance_Stop
      fi
    done
  else
  vpcRt=()
  tgwNAT=()
  sleep $Wait_Between_Pings
  fi
done