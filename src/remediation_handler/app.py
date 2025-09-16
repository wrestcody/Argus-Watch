import json
import logging
import os
import boto3
from opa_policy import OPAPolicy

# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Load the OPA policy from the bundled .rego file
# This assumes 'remediation.rego' is in the same directory as 'app.py'
try:
    policy_path = os.path.join(os.path.dirname(__file__), 'remediation.rego')
    opa_policy = OPAPolicy.from_file(policy_path)
except Exception as e:
    logger.error(f"Failed to load OPA policy: {e}")
    # If the policy can't load, the function is non-operational
    opa_policy = None

# A mapping to translate a generic 'targetIdentifier' to the specific
# keyword argument required by a given boto3 function.
# This could be expanded or moved to a separate config file.
BOTO3_IDENTIFIER_MAP = {
    "rds": {
        "modify_db_instance": "DBInstanceIdentifier"
    },
    "s3": {
        "put_public_access_block": "Bucket"
    }
}

def lambda_handler(event, context):
    """
    API Gateway Lambda handler to execute remediations based on an OPA policy.
    """
    if not opa_policy:
        return format_response(500, {"error": "OPA policy is not loaded, cannot proceed."})

    try:
        # 1. Parse the security finding from the request body
        try:
            finding = json.loads(event.get('body', '{}'))
            if not finding:
                logger.warning("Request body is empty or invalid.")
                return format_response(400, {"error": "Request body must contain a valid JSON finding."})
        except json.JSONDecodeError as e:
            logger.error(f"Failed to parse JSON body: {e}")
            return format_response(400, {"error": "Invalid JSON in request body."})

        logger.info(f"Received finding for evaluation: {finding.get('InstanceIdentifier')}")

        # 2. Evaluate the finding against the OPA policy
        decision = opa_policy.evaluate(finding)
        actions = decision.get('actions', [])

        if not actions:
            logger.info("No matching remediation action found in OPA policy.")
            return format_response(200, {
                "message": "No remediation action defined for this finding.",
                "finding": finding
            })

        # 3. Execute the prescribed remediation actions
        results = []
        for action in actions:
            logger.info(f"Executing action: {action}")
            try:
                result = execute_boto3_call(action)
                results.append({"action": action, "status": "SUCCESS", "result": result})
            except Exception as e:
                logger.error(f"Failed to execute action {action}: {e}")
                results.append({"action": action, "status": "FAILED", "error": str(e)})
                # If any action fails, return a 500 error for the whole execution
                return format_response(500, {"message": "One or more remediation actions failed.", "results": results})

        logger.info("All remediation actions executed successfully.")
        return format_response(200, {"message": "Remediation executed successfully.", "results": results})

    except Exception as e:
        logger.error(f"An unexpected error occurred: {e}")
        return format_response(500, {"error": "An internal server error occurred."})

def execute_boto3_call(action: dict):
    """
    Dynamically constructs and executes a boto3 API call based on the action object.
    """
    service = action['service']
    api_call = action['apiCall']
    target_id = action['targetIdentifier']
    parameters = action.get('parameters', {})

    # Determine the correct identifier key for the boto3 call
    identifier_key = BOTO3_IDENTIFIER_MAP.get(service, {}).get(api_call)
    if not identifier_key:
        raise ValueError(f"Could not find the identifier key for service '{service}' and apiCall '{api_call}'.")

    # Add the target identifier to the parameters
    parameters[identifier_key] = target_id

    # Create the boto3 client and execute the call
    client = boto3.client(service)
    method_to_call = getattr(client, api_call)

    logger.info(f"Executing: {service}.{api_call} with parameters: {parameters}")
    response = method_to_call(**parameters)

    # Remove noisy metadata before returning
    response.pop('ResponseMetadata', None)
    return response

def format_response(status_code, body):
    """
    Formats the Lambda response for API Gateway.
    """
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "application/json"
        },
        "body": json.dumps(body)
    }
