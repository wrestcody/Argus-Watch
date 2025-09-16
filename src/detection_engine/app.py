import boto3
import json
import logging
import os
import yaml
import jmespath

# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Environment variables
SNS_TOPIC_ARN = os.environ.get('SNS_TOPIC_ARN')
AWS_REGION = os.environ.get('AWS_REGION')

# Initialize clients
try:
    sns_client = boto3.client('sns', region_name=AWS_REGION)
except Exception as e:
    logger.error(f"Error initializing SNS client: {e}")
    raise

def load_controls():
    """Loads the controls manifest from the bundled YAML file."""
    try:
        # The controls.yaml file is expected to be in the same directory
        controls_path = os.path.join(os.path.dirname(__file__), 'controls.yaml')
        with open(controls_path, 'r') as f:
            return yaml.safe_load(f).get('controls', [])
    except Exception as e:
        logger.error(f"Failed to load or parse controls.yaml: {e}")
        return []

def lambda_handler(event, context):
    """
    A generic detection engine that evaluates controls from a manifest file.
    """
    logger.info("Starting detection engine run.")

    if not SNS_TOPIC_ARN:
        logger.error("SNS_TOPIC_ARN environment variable is not set.")
        return {'statusCode': 500, 'body': 'SNS topic not configured.'}

    controls = load_controls()
    if not controls:
        logger.error("No controls loaded. Exiting.")
        return {'statusCode': 500, 'body': 'Controls manifest is empty or failed to load.'}

    all_findings = []
    for control in controls:
        logger.info(f"Evaluating control: {control['controlID']}")
        try:
            findings = evaluate_control(control, context)
            for finding in findings:
                publish_finding(finding)
                all_findings.append(finding)
        except Exception as e:
            logger.error(f"Failed to evaluate control {control['controlID']}: {e}")

    logger.info(f"Detection engine run complete. Published {len(all_findings)} findings.")
    return {
        'statusCode': 200,
        'body': json.dumps({
            'message': 'Detection engine run finished.',
            'findings_count': len(all_findings)
        })
    }

def evaluate_control(control: dict, context: object) -> list:
    """Evaluates a single control against AWS resources."""
    findings = []
    detection_cfg = control['detection']
    service_name = detection_cfg['service']
    list_method = detection_cfg['listMethod']
    resource_id_key = detection_cfg['resourceIdentifier']

    client = boto3.client(service_name, region_name=AWS_REGION)

    try:
        # Use a paginator for list calls to handle large resource counts
        paginator = client.get_paginator(list_method)
        pages = paginator.paginate()

        for page in pages:
            # The key for the list of resources varies by API call (e.g., 'DBInstances', 'Buckets')
            resource_list_key = list(page.keys())[1] # Heuristic: second key is usually the list
            for resource in page[resource_list_key]:
                evaluation_target = resource

                # Handle sub-calls if defined (e.g., for S3 encryption)
                if 'subCall' in detection_cfg:
                    try:
                        sub_call_cfg = detection_cfg['subCall']
                        params = {}
                        for param in sub_call_cfg.get('parameters', []):
                            if param['source'] == 'resourceIdentifier':
                                params[param['name']] = resource[resource_id_key]

                        sub_call_method = getattr(client, sub_call_cfg['method'])
                        evaluation_target = sub_call_method(**params)
                    except Exception as e:
                        # If sub-call fails (e.g., GetBucketEncryption on a bucket that was just deleted), log and skip.
                        logger.warning(f"Sub-call failed for resource {resource[resource_id_key]}: {e}")
                        continue

                # Evaluate compliance using JMESPath
                is_compliant = jmespath.search(detection_cfg['evaluation']['expression'], evaluation_target)

                if not is_compliant:
                    logger.warning(f"Non-compliant resource found for {control['controlID']}: {resource[resource_id_key]}")
                    finding = {
                        'controlID': control['controlID'],
                        'AccountId': context.invoked_function_arn.split(":")[4],
                        'Region': AWS_REGION,
                        'InstanceIdentifier': resource[resource_id_key],
                        'FindingDescription': control['description'],
                        'Status': 'NON_COMPLIANT',
                        'Severity': control['severity']
                    }
                    findings.append(finding)

    except Exception as e:
        logger.error(f"Error processing control {control['controlID']} with Boto3: {e}")

    return findings

def publish_finding(finding: dict):
    """Publishes a JSON-formatted finding to the configured SNS topic."""
    try:
        sns_client.publish(
            TopicArn=SNS_TOPIC_ARN,
            Message=json.dumps(finding, indent=4),
            Subject=f"Argus-Watch Finding: {finding['controlID']} - {finding['InstanceIdentifier']}"
        )
        logger.info(f"Successfully published finding for {finding['InstanceIdentifier']}")
    except Exception as e:
        logger.error(f"Failed to publish finding to SNS: {e}")
        # Re-raise to ensure the main handler is aware of the failure
        raise
