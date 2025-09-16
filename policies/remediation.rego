package argus.remediation

# By default, the list of actions is empty.
default actions = []

# Rule for AWS.RDS.1: Ensure RDS instances have backups enabled.
actions[action] {
    input.controlID == "AWS.RDS.1"

    action := {
        "service": "rds",
        "apiCall": "modify_db_instance",
        "targetIdentifier": input.InstanceIdentifier,
        "parameters": {
            "BackupRetentionPeriod": 7,
            "ApplyImmediately": true
        }
    }
}

# Rule for AWS.S3.1: Ensure S3 buckets have server-side encryption enabled.
actions[action] {
    input.controlID == "AWS.S3.1"

    action := {
        "service": "s3",
        "apiCall": "put_bucket_encryption",
        "targetIdentifier": input.InstanceIdentifier, # The detection engine uses 'InstanceIdentifier' generically
        "parameters": {
            "ServerSideEncryptionConfiguration": {
                "Rules": [
                    {
                        "ApplyServerSideEncryptionByDefault": {
                            "SSEAlgorithm": "AES256"
                        }
                    }
                ]
            }
        }
    }
}
