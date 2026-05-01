<script>
  import { detectLiveness } from '@ensombl/tauri-plugin-rekognition-liveness-api';
  import {
    createLivenessSession,
    fetchLivenessResults,
    mintSessionToken,
  } from './lib/aws.js';

  // Persisted long-lived IAM credentials. Stored in localStorage so you only
  // paste them once during dev — never use this pattern in a production app.
  const STORAGE_KEY = 'tauri-plugin-rekognition-liveness-demo:iam';
  const stored = (() => {
    try {
      return JSON.parse(localStorage.getItem(STORAGE_KEY) ?? '{}');
    } catch {
      return {};
    }
  })();

  let accessKeyId = $state(stored.accessKeyId ?? '');
  let secretAccessKey = $state(stored.secretAccessKey ?? '');
  let region = $state(stored.region ?? 'us-east-1');
  /** @type {'front' | 'back'} */
  let camera = $state(stored.camera ?? 'front');

  let pluginResult = $state(/** @type {object | null} */ (null));
  let livenessResults = $state(/** @type {object | null} */ (null));
  let phase = $state(
    /** @type {'idle' | 'minting' | 'creating' | 'detecting' | 'fetching' | 'done' | 'error'} */ (
      'idle'
    ),
  );
  let errorMessage = $state(/** @type {string | null} */ (null));

  const phaseLabel = {
    idle: 'Run Liveness',
    minting: 'Minting STS session token…',
    creating: 'Creating Liveness session…',
    detecting: 'Running native Liveness flow…',
    fetching: 'Fetching results…',
    done: 'Run Liveness again',
    error: 'Run Liveness',
  };

  const canRun = $derived(
    accessKeyId.trim() &&
      secretAccessKey.trim() &&
      region.trim() &&
      phase !== 'minting' &&
      phase !== 'creating' &&
      phase !== 'detecting' &&
      phase !== 'fetching',
  );

  function persist() {
    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({ accessKeyId, secretAccessKey, region, camera }),
    );
  }

  async function run() {
    persist();
    pluginResult = null;
    livenessResults = null;
    errorMessage = null;
    try {
      phase = 'minting';
      const tempCreds = await mintSessionToken(
        { accessKeyId, secretAccessKey },
        region,
      );

      phase = 'creating';
      const bundle = await createLivenessSession(tempCreds, region, camera);

      phase = 'detecting';
      pluginResult = await detectLiveness({
        sessionId: bundle.sessionId,
        region: bundle.region,
        credentials: bundle.credentials,
        camera: bundle.camera,
      });

      if (pluginResult?.status === 'success') {
        phase = 'fetching';
        livenessResults = await fetchLivenessResults(
          bundle.sessionId,
          tempCreds,
          region,
        );
      }

      phase = 'done';
    } catch (err) {
      errorMessage = err instanceof Error ? err.message : String(err);
      phase = 'error';
    }
  }
</script>

<main>
  <h1>AWS Face Liveness — plugin demo</h1>
  <p>
    Drives the plugin end-to-end without a backend. Paste your long-lived
    IAM access key + secret <em>once</em> (persisted to localStorage) — the
    demo derives a 15-minute STS session token, creates a Face Liveness
    session, runs the native flow on the device, and fetches the result
    from <code>GetFaceLivenessSessionResults</code>.
  </p>

  <div class="hint">
    The IAM principal needs Rekognition + STS permissions. With
    <code>AmazonRekognitionFullAccess</code> already attached, you also need
    <code>sts:GetSessionToken</code> (granted to all IAM users by default).
    Don't ship long-lived creds inside a real mobile app.
  </div>

  <label for="region">Region</label>
  <input id="region" bind:value={region} placeholder="us-east-1" />

  <label for="ak">Access key ID</label>
  <input id="ak" bind:value={accessKeyId} placeholder="AKIA..." />

  <label for="sk">Secret access key</label>
  <input id="sk" type="password" bind:value={secretAccessKey} />

  <fieldset class="camera">
    <legend>Camera</legend>
    <label>
      <input type="radio" name="camera" value="front" bind:group={camera} />
      Front (default · supports light + movement challenge)
    </label>
    <label>
      <input type="radio" name="camera" value="back" bind:group={camera} />
      Back (verify someone else · forces FaceMovement-only)
    </label>
    {#if camera === 'back'}
      <p class="hint-inline">
        Back camera disables the on-screen color-flash anti-spoof. The demo
        creates the session with
        <code>ChallengePreferences = [FaceMovementChallenge]</code>
        so AWS won't reject the streaming connection.
      </p>
    {/if}
  </fieldset>

  <button type="button" onclick={run} disabled={!canRun}>
    {phaseLabel[phase]}
  </button>

  {#if phase === 'error'}
    <pre class="err">Error: {errorMessage}</pre>
  {/if}

  {#if pluginResult}
    <h2>Plugin result</h2>
    <pre>{JSON.stringify(pluginResult, null, 2)}</pre>
  {/if}

  {#if livenessResults}
    <h2>GetFaceLivenessSessionResults</h2>
    <p class="summary">
      <strong>Status:</strong> {livenessResults.Status}
      &nbsp;·&nbsp;
      <strong>Confidence:</strong>
      {livenessResults.Confidence?.toFixed(2)} / 100
    </p>
    <pre>{JSON.stringify(
      {
        SessionId: livenessResults.SessionId,
        Status: livenessResults.Status,
        Confidence: livenessResults.Confidence,
        ReferenceImage: livenessResults.ReferenceImage
          ? '<bytes/s3 omitted>'
          : null,
        AuditImagesCount: livenessResults.AuditImages?.length ?? 0,
      },
      null,
      2,
    )}</pre>
  {/if}
</main>
