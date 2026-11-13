import { S3Client, GetObjectCommand } from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';

// Railway Buckets are S3-compatible. Reference the bucket's variables on the API service, e.g.
// BUCKET=${{bucket.BUCKET}} ENDPOINT=${{bucket.ENDPOINT}} and so on. S3_* names also work.
export function bucketConfig(env = process.env) {
  const pick = (...names) => names.map((n) => env[n]).find(Boolean);
  const cfg = {
    bucket: pick('BUCKET', 'S3_BUCKET', 'BUCKET_NAME'),
    endpoint: pick('ENDPOINT', 'S3_ENDPOINT', 'BUCKET_ENDPOINT'),
    region: pick('REGION', 'S3_REGION', 'AWS_REGION') ?? 'auto',
    accessKeyId: pick('ACCESS_KEY_ID', 'S3_ACCESS_KEY_ID', 'AWS_ACCESS_KEY_ID'),
    secretAccessKey: pick('SECRET_ACCESS_KEY', 'S3_SECRET_ACCESS_KEY', 'AWS_SECRET_ACCESS_KEY'),
    forcePathStyle: (pick('S3_FORCE_PATH_STYLE') ?? 'false') === 'true',
  };
  return cfg.bucket && cfg.endpoint && cfg.accessKeyId && cfg.secretAccessKey ? cfg : null;
}

export function createStorage(cfg, { ttlSeconds = 600 } = {}) {
  if (!cfg) return null;
  const client = new S3Client({
    region: cfg.region,
    endpoint: cfg.endpoint,
    forcePathStyle: cfg.forcePathStyle,
    credentials: { accessKeyId: cfg.accessKeyId, secretAccessKey: cfg.secretAccessKey },
  });
  return {
    client,
    bucket: cfg.bucket,
    ttlSeconds,
    async presign(key, filename) {
      const cmd = new GetObjectCommand({
        Bucket: cfg.bucket,
        Key: key,
        ResponseContentDisposition: filename ? `attachment; filename="${filename.replace(/"/g, '')}"` : undefined,
      });
      return getSignedUrl(client, cmd, { expiresIn: ttlSeconds });
    },
  };
}
