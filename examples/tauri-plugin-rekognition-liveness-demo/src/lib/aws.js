import {
  CreateFaceLivenessSessionCommand,
  GetFaceLivenessSessionResultsCommand,
  RekognitionClient,
} from '@aws-sdk/client-rekognition';
import { GetSessionTokenCommand, STSClient } from '@aws-sdk/client-sts';

/**
 * @typedef {object} StaticCredentials
 * @property {string} accessKeyId
 * @property {string} secretAccessKey
 *
 * @typedef {object} TemporaryCredentials
 * @property {string} accessKeyId
 * @property {string} secretAccessKey
 * @property {string} sessionToken
 * @property {string} expiresAt   ISO 8601
 *
 * @typedef {object} LivenessSessionBundle
 * @property {string} sessionId
 * @property {string} region
 * @property {TemporaryCredentials} credentials
 */

/**
 * Mint a 15-minute session token from the user's long-lived IAM credentials.
 * `aws sts get-session-token` semantics — no role to assume, works with any
 * IAM user that has at least `sts:GetSessionToken`.
 *
 * @param {StaticCredentials} iam
 * @param {string} region
 * @returns {Promise<TemporaryCredentials>}
 */
export async function mintSessionToken(iam, region) {
  const sts = new STSClient({ region, credentials: iam });
  const out = await sts.send(
    new GetSessionTokenCommand({ DurationSeconds: 900 }),
  );
  const creds = out.Credentials;
  if (
    !creds?.AccessKeyId ||
    !creds.SecretAccessKey ||
    !creds.SessionToken ||
    !creds.Expiration
  ) {
    throw new Error('STS GetSessionToken returned an incomplete credential set');
  }
  return {
    accessKeyId: creds.AccessKeyId,
    secretAccessKey: creds.SecretAccessKey,
    sessionToken: creds.SessionToken,
    expiresAt: creds.Expiration.toISOString(),
  };
}

/**
 * Create a Face Liveness session and bundle it with the temporary credentials
 * the plugin will hand to the device-side Amplify SDK.
 *
 * When `camera === 'back'`, the session must run the FaceMovementChallenge
 * (head-movement only, no on-screen color flash) — the FaceMovementAndLight
 * challenge requires the front camera by definition. We pass an explicit
 * `Settings.ChallengePreferences` to opt in.
 *
 * @param {TemporaryCredentials} credentials
 * @param {string} region
 * @param {'front' | 'back'} [camera='front']
 * @returns {Promise<LivenessSessionBundle & { camera: 'front' | 'back' }>}
 */
export async function createLivenessSession(credentials, region, camera = 'front') {
  const rekognition = new RekognitionClient({ region, credentials });
  /** @type {import('@aws-sdk/client-rekognition').CreateFaceLivenessSessionCommandInput} */
  const input = camera === 'back'
    ? {
        Settings: {
          ChallengePreferences: [
            {
              Type: 'FaceMovementChallenge',
              Versions: { Minimum: '1.0.0', Maximum: '1.0.0' },
            },
          ],
        },
      }
    : {};
  const out = await rekognition.send(new CreateFaceLivenessSessionCommand(input));
  if (!out.SessionId) throw new Error('CreateFaceLivenessSession returned no SessionId');
  return { sessionId: out.SessionId, region, credentials, camera };
}

/**
 * Fetch the final Liveness verdict + confidence after the device-side flow
 * resolves with `status: 'success'`.
 *
 * @param {string} sessionId
 * @param {TemporaryCredentials} credentials
 * @param {string} region
 */
export async function fetchLivenessResults(sessionId, credentials, region) {
  const rekognition = new RekognitionClient({ region, credentials });
  return rekognition.send(
    new GetFaceLivenessSessionResultsCommand({ SessionId: sessionId }),
  );
}
