import boto3
import uuid
import datetime

def create_s3_bucket(bucket_name, region):
    s3_client = boto3.client('s3', region_name=region)
    print(f"Attempting to create S3 bucket: '{bucket_name}' in region: '{region}'...")

    try:
        if region == 'us-east-1':
            s3_client.create_bucket(Bucket=bucket_name)
        else:
            s3_client.create_bucket(
                Bucket=bucket_name,
                CreateBucketConfiguration={'LocationConstraint': region}
            )
        print(f"S3 bucket '{bucket_name}' created successfully in region '{region}'.")
        return True
    except s3_client.exceptions.BucketAlreadyOwnedByYou:
        print(f"S3 bucket '{bucket_name}' already exists and is owned by you.")
        return True
    except s3_client.exceptions.BucketAlreadyExists:
        print(f"Error: S3 bucket '{bucket_name}' already exists globally.")
        return False
    except Exception as e:
        print(f"Error creating S3 bucket '{bucket_name}': {e}")
        return False

def generate_unique_bucket_name(base_name):
    """
    Generates a globally unique bucket name by adding a timestamp and UUID suffix.
    """
    timestamp = datetime.datetime.now().strftime("%y%m%d")
    unique_suffix = str(uuid.uuid4())[:8] 
    return f"{base_name}-{timestamp}-{unique_suffix}".lower()

if __name__ == "__main__":
    base_name = 'demo-artifacts'
    my_region = 'ap-southeast-1' 
    my_unique_bucket_name = generate_unique_bucket_name(base_name)
    create_s3_bucket(my_unique_bucket_name, my_region)