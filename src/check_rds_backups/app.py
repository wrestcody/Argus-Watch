import boto3
import json
import logging
import os

# Configure structured logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Environment variables
SNS_TOPIC_ARN = os.environ.get('SNS_TOPIC_ARN')
AWS_REGION = os.environ.get('AWS_REGION')

# Initialize AWS clients
try:
    rds_client = boto3.client('rds', region_name=AWS_REGION)
    sns_client = boto3.client('sns', region_name=AWS_REGION)
except Exception as e:
    logger.error(f"Error initializing AWS clients: {e}")
    raise

def lambda_handler(event, context):
    """
    Lambda function to scan RDS instances for automated backup and PITR compliance.

    This function is triggered by an event (e.g., EventBridge schedule) and iterates
    through all RDS instances in the specified region. It checks if automated backups
    are enabled (BackupRetentionPeriod > 0). If an instance is non-compliant,
    it publishes a finding to an SNS topic.

    Args:
        event (dict): The event that triggered the Lambda function.
        context (object): The Lambda runtime information.

    Returns:
        dict: A summary of the execution results.
    """
    logger.info("Starting RDS backup compliance check.")

    if not SNS_TOPIC_ARN:
        logger.error("SNS_TOPIC_ARN environment variable is not set.")
        return {
            'statusCode': 500,
            'body': json.dumps('Internal server error: SNS topic ARN not configured.')
        }

    non_compliant_instances = []

    try:
        # Use a paginator to handle large numbers of RDS instances
        paginator = rds_client.get_paginator('describe_db_instances')
        pages = paginator.paginate()

        for page in pages:
            for instance in page['DBInstances']:
                instance_identifier = instance['DBInstanceIdentifier']
                backup_retention_period = instance.get('BackupRetentionPeriod', 0)

                # Check for compliance: automated backups are enabled if retention period > 0
                # This is the primary requirement for Point-in-Time Recovery (PITR).
                if backup_retention_period == 0:
                    logger.warning(
                        f"Non-compliant instance found: {instance_identifier}. "
                        f"Automated backups are disabled (BackupRetentionPeriod is 0)."
                    )

                    finding = {
                        'AccountId': context.invoked_function_arn.split(":")[4],
                        'Region': AWS_REGION,
                        'InstanceIdentifier': instance_identifier,
                        'FindingDescription': 'RDS instance does not have automated backups enabled, which is required for Point-in-Time Recovery (PITR).',
                        'Status': 'NON_COMPLIANT'
                    }

                    # Publish the finding to the SNS topic
                    publish_finding(finding)
                    non_compliant_instances.append(instance_identifier)

    except Exception as e:
        logger.error(f"An error occurred during RDS scan: {e}")
        # Depending on requirements, you might want to send a notification about the failure
        return {
            'statusCode': 500,
            'body': json.dumps('An error occurred during the compliance scan.')
        }

    logger.info(f"Compliance check complete. Found {len(non_compliant_instances)} non-compliant instances.")

    return {
        'statusCode': 200,
        'body': json.dumps({
            'message': 'RDS backup compliance check finished successfully.',
            'non_compliant_instances': non_compliant_instances
        })
    }

def publish_finding(finding):
    """
    Publishes a JSON-formatted finding to the configured SNS topic.

    Args:
        finding (dict): The finding to publish.
    """
    try:
        response = sns_client.publish(
            TopicArn=SNS_TOPIC_ARN,
            Message=json.dumps(finding, indent=4),
            Subject=f"Argus-Watch Finding: Non-Compliant RDS Instance - {finding['InstanceIdentifier']}"
        )
        logger.info(f"Successfully published finding for instance {finding['InstanceIdentifier']} to SNS. MessageId: {response['MessageId']}")
    except Exception as e:
        logger.error(f"Failed to publish finding for instance {finding['InstanceIdentifier']} to SNS topic {SNS_TOPIC_ARN}. Error: {e}")
        # Raise the exception to ensure the main handler is aware of the failure
        raise
