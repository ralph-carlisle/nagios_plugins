#!/bin/bash
# Author:       Ralph Carlisle [rcarlisle@proofpoint.com]
# Date:         2019-Aug-07


if ! which awk > /dev/null; then
    printf "ERROR:  awk binary not found"
    printf "\n        This file should have been set on the system by puppet."
    exit "$NAGIOS_UNKNOWN"
fi

if ! which aws > /dev/null; then
    printf "ERROR:  aws cli binary not found"
    printf "\n        This file should have been set on the system by puppet."
    exit "$NAGIOS_UNKNOWN"
fi

if ! which head > /dev/null; then
    printf "ERROR:  head binary not found"
    printf "\n        This file should have been set on the system by puppet."
    exit "$NAGIOS_CRITICAL"
fi

if ! which jq > /dev/null; then
    printf "ERROR:  jq binary not found"
    printf "\n        This file should have been set on the system by puppet."
    exit "$NAGIOS_CRITICAL"
fi

INT_ONLY='^([1-9]|[1-9][0-9]*)$'
NAGIOS_OK=0
NAGIOS_WARNING=1
NAGIOS_CRITICAL=2
NAGIOS_UNKNOWN=3
MINIMUM_AWS="1.16.40"
INSTALLED_AWS=$(aws --version 2>&1 | awk '{print $1}' | awk -F/ '{print $2}')

if [[ ! "$(printf '%s\n' "$MINIMUM_AWS" "$INSTALLED_AWS" | sort -V | head -n1)" == "$MINIMUM_AWS" ]]; then
    printf "ERROR:  The installed aws cli version [%s] needs to be greater than or equal to [%s]" "$INSTALLED_AWS" "$MINIMUM_AWS"
    exit "$NAGIOS_CRITICAL"
fi

read -d '' -r USAGE <<"EOF"
This Nagios plugin queries the number of unhealthy instances associated with the specified
Target Group's ARN and will generate a CRITICAL alert if no connected instance is reported
as Healthy.
The plugin will also query the LB's ClientTLSNegotiationErrorCount CloudWatch
metric and generate a CRITICAL alert if any result is returned in the specified time period.
Any reported Unhealthy instances will result in a WARNING alert if the number is below the 
critical threshold; ie:  if critical threshold is set to 5 and 1 connected instance is unhealthy,
then the plugin will return a WARNING alert.
The AWS credentials will need to have read permissions for cloudwatch (use nagios-cloudwatch-api key).

Required Parameters:
    -c <critical threshold>        [MANDATORY] The number of Unhealthy instances required to
                                       generate a Critical Alert
    -i <AWS_ACCESS_KEY_ID>         [MANDATORY] The AWS_ACCESS_KEY_ID
    -k <AWS_SECRET_ACCESS_KEY>     [MANDATORY] The AWS_SECRET_ACCESS_KEY
    -l <Load Balancer Name>        [MANDATORY] The AWS name of the Load Balancer; should look
                                       like:  app/rcarlisle-test/0ea29075d6197148
    -p <Period>                    [OPTIONAL]  The amount of time in seconds to query against
                                       This should be a multiple of 60.  Defaults to 3600 if not
                                       otherwise specified (1 hour)
    -r <AWS Region>                [OPTIONAL] The AWS region to interact, like us-east-1
                                       Defaults to us-east-1 if not otherwise specified
    -t <Target Group>              [MANDATORY] The AWS name of the Load Balancer's Target Group
                                       Should look like:  targetgroup/rcarlisle-test/8fdf9f87506d2cb5
EOF

while getopts :c:i:k:l:p:r:t: param; do
  case "${param}" in
    c)  CRIT_THRESHOLD="${OPTARG}"
        ;;
    i)  AWS_ACCESS_KEY_ID="${OPTARG}"
        ;;
    k)  AWS_SECRET_ACCESS_KEY="${OPTARG}"
        ;;
    l)  LBNAME="${OPTARG}"
        ;;
    p)  PERIOD="${OPTARG}"
        ;;
    r)  REGION="${OPTARG}"
        ;;
    t)  TARGETGROUP="${OPTARG}"
        ;;
    *)  printf "Invalid option or missing value: -%s" "$OPTARG"
        printf "\n%s\n" "$USAGE"
        exit "$NAGIOS_UNKNOWN"
        ;;
  esac
done

if [[ -z ${CRIT_THRESHOLD+x} ]]; then
    printf "ERROR:  -c (no value supplied)"
    printf "\n%s\n" "$USAGE"
    exit "$NAGIOS_CRITICAL"
fi

if ! [[ "$CRIT_THRESHOLD" =~ $INT_ONLY ]]; then
    printf "ERROR: -c (%s) is not a non-zero integer" "$CRIT_THRESHOLD"
    printf "\n%s\n" "$USAGE"
    exit "$NAGIOS_CRITICAL"
fi

if [[ -z ${AWS_ACCESS_KEY_ID+x} ]]; then
    printf "ERROR:  -i (no value supplied)"
    printf "\n%s\n" "$USAGE"
    exit "$NAGIOS_CRITICAL"
fi

if [[ -z ${AWS_SECRET_ACCESS_KEY+x} ]]; then
    printf "ERROR:  -k (no value supplied)"
    printf "\n%s\n" "$USAGE"
    exit "$NAGIOS_CRITICAL"
fi

if [[ -z ${LBNAME+x} ]]; then
    printf "ERROR:  -l (no value supplied)"
    printf "\n%s\n" "$USAGE"
    exit "$NAGIOS_CRITICAL"
fi

if [[ -z ${PERIOD+x} ]]; then
    PERIOD=3600
fi

if ! [[ "$PERIOD" =~ $INT_ONLY ]]; then
    printf "ERROR: -p (%s) is not a non-zero integer" "$PERIOD"
    printf "\n%s\n" "$USAGE"
    exit "$NAGIOS_CRITICAL"
fi

if [[ $(( PERIOD % 60 )) -ne 0 ]]; then
    printf "ERROR:  Value of -p [%s] is invalid; not a multiple of 60" "$PERIOD"
    printf "\n%s\n" "$USAGE"
    exit "$NAGIOS_CRITICAL"
fi

if [[ -z ${REGION+x} ]]; then
    REGION="us-east-1"
fi

if [[ -z ${TARGETGROUP+x} ]]; then
    printf "ERROR:  -t (no value supplied)"
    printf "\n%s\n" "$USAGE"
    exit "$NAGIOS_CRITICAL"
fi

### Supportive URL : http://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSGettingStartedGuide/AWSCredentials.html ###
export AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION="$REGION"

DATEBEGIN=$(date +"%Y-%m-%dT%T" --date=''"$PERIOD"' seconds ago')
DATEEND=$(date +"%Y-%m-%dT%T")
QUERYFILE_HEALTHY=/tmp/getLBmetrics_healthy.json
QUERYFILE_SSL=/tmp/getLBmetrics_ssl.json
QUERYFILE_UNHEALTHY=/tmp/getLBmetrics_unhealthy.json

# ensure the file is not stale
if [[ -f "${QUERYFILE_HEALTHY}" ]]; then
    rm -rf "$QUERYFILE_HEALTHY"
fi

# ensure the file is not stale
if [[ -f "${QUERYFILE_SSL}" ]]; then
    rm -rf "$QUERYFILE_SSL"
fi

# ensure the file is not stale
if [[ -f "${QUERYFILE_UNHEALTHY}" ]]; then
    rm -rf "$QUERYFILE_UNHEALTHY"
fi

JSONCONTENT_HEALTHY='
[
    {
      "Id": "m1",
      "MetricStat": {
        "Metric": {
          "Namespace": "AWS/ApplicationELB",
          "MetricName": "HealthyHostCount",
          "Dimensions": [
            {
              "Name": "LoadBalancer",
              "Value": "'${LBNAME}'"
            },
            {
              "Name": "TargetGroup",
              "Value": "'${TARGETGROUP}'"
            }
          ]
        },
        "Period": '${PERIOD}',
        "Stat": "Average"
      },
      "ReturnData": true
    }
]'
echo "$JSONCONTENT_HEALTHY" >> "$QUERYFILE_HEALTHY"

if [[ ! -f "${QUERYFILE_HEALTHY}" ]]; then
    printf "ERROR:  [%s] not found" "$QUERYFILE_HEALTHY"
    printf "\n        This file should have been set on the system by this plugin."
    exit "$NAGIOS_CRITICAL"
fi

JSONCONTENT_SSL='
[
    {
      "Id": "m1",
      "MetricStat": {
        "Metric": {
          "Namespace": "AWS/ApplicationELB",
          "MetricName": "ClientTLSNegotiationErrorCount",
          "Dimensions": [
            {
              "Name": "LoadBalancer",
              "Value": "'${LBNAME}'"
            }
          ]
        },
        "Period": '${PERIOD}',
        "Stat": "SampleCount"
      },
      "ReturnData": true
    }
]'
echo "$JSONCONTENT_SSL" >> "$QUERYFILE_SSL"

if [[ ! -f "${QUERYFILE_SSL}" ]]; then
    printf "ERROR:  [%s] not found" "$QUERYFILE_SSL"
    printf "\n        This file should have been set on the system by this plugin."
    exit "$NAGIOS_CRITICAL"
fi

JSONCONTENT_UNHEALTHY='
[
    {
      "Id": "m1",
      "MetricStat": {
        "Metric": {
          "Namespace": "AWS/ApplicationELB",
          "MetricName": "UnHealthyHostCount",
          "Dimensions": [
            {
              "Name": "LoadBalancer",
              "Value": "'${LBNAME}'"
            },
            {
              "Name": "TargetGroup",
              "Value": "'${TARGETGROUP}'"
            }
          ]
        },
        "Period": '${PERIOD}',
        "Stat": "Average"
      },
      "ReturnData": true
    }
]'
echo "$JSONCONTENT_UNHEALTHY" >> "$QUERYFILE_UNHEALTHY"

if [[ ! -f "${QUERYFILE_UNHEALTHY}" ]]; then
    printf "ERROR:  [%s] not found" "$QUERYFILE_UNHEALTHY"
    printf "\n        This file should have been set on the system by this plugin."
    exit "$NAGIOS_CRITICAL"
fi

NUM_HEALTHY=$(aws cloudwatch get-metric-data --start-time "$DATEBEGIN" --end-time "$DATEEND" --metric-data-queries file://"$QUERYFILE_HEALTHY" | jq '.[] | .[] | .Values | .[]' | head -n 1)
NUM_UNHEALTHY=$(aws cloudwatch get-metric-data --start-time "$DATEBEGIN" --end-time "$DATEEND" --metric-data-queries file://"$QUERYFILE_UNHEALTHY" | jq '.[] | .[] | .Values | .[]' | head -n 1)
NUM_TLSERRORS=$(aws cloudwatch get-metric-data --start-time "$DATEBEGIN" --end-time "$DATEEND" --metric-data-queries file://"$QUERYFILE_SSL" | jq '.[] | .[] | .Values | .[]' | head -n 1)

# critical if there are any SSL errors reported by the LB attempting to connect to the instances
if [[ -n "$NUM_TLSERRORS" ]]; then
    printf "CRITICAL:  Load Balancer is reporting [%s] TLS Negotiation Errors; check your Load Balancer [%s]" "$NUM_TLSERRORS" "$LBNAME"
    exit "$NAGIOS_CRITICAL"
fi

# Cloudwatch reported metrics can be floats so we need to handle that by using bc
if [[ -z ${NUM_HEALTHY+x} ]] || [[ $(echo "$NUM_HEALTHY == 0" | bc) -ne 0 ]]; then
    printf "CRITICAL:  No instances are listed as healthy; check your Load Balancer [%s]" "$LBNAME"
    exit "$NAGIOS_CRITICAL"
fi

if [[ $(echo "$NUM_UNHEALTHY >= $CRIT_THRESHOLD" | bc) -ne 0 ]]; then
    printf "CRITICAL:  [%s] instances are unhealthy and threshold is set to [%s]; check your Load Balancer [%s]" "$NUM_UNHEALTHY" "$CRIT_THRESHOLD" "$LBNAME"
    exit "$NAGIOS_CRITICAL"
elif [[ $(echo "$NUM_UNHEALTHY < $CRIT_THRESHOLD" | bc) -ne 0 ]] && [[ $(echo "$NUM_UNHEALTHY > 0" | bc) -ne 0 ]]; then
    printf "WARNING:  [%s] instances are unhealthy and threshold is set to [%s]; check your Load Balancer [%s]" "$NUM_UNHEALTHY" "$CRIT_THRESHOLD" "$LBNAME"
    exit "$NAGIOS_WARNING"
elif [[ $(echo "$NUM_UNHEALTHY == 0" | bc) -ne 0 ]]; then
    printf "OK: [%s] instances are unhealthy" "$NUM_UNHEALTHY"
    exit "$NAGIOS_OK"
fi