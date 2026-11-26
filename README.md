# Goodest Notes

Goodest Notes is a native iPad notebook for teaching with Apple Pencil, PDFs, whiteboards, reusable blocks, and a shared project conversation. A teacher can lasso a drawing, direct its movement, replay it on the page, and keep writing. Claude and ChatGPT can work on the same project from separate chats.

## Try the notebook

Open the Xcode project with Xcode 27 or later. Select the Blockbook scheme, select your signing team, choose an iPad, and run. The product displays **Goodest Notes**. The original bundle ID is `com.btbt.blockbook`. Updating an existing installation requires its original signing team. For an independent installation, choose your own bundle identifier in the app and test targets.

Tap **Open circuit lesson** on the writing desk. Play the teaching visual and watch the switch close before the filament lights. Turn motion off to edit the original ink. On any page, choose the wand, draw a closed lasso around your strokes, and open Drawing studio. Choose the moving strokes, adjust the hinge or travel distance, and scrub through the contact frame. The optional signal and light controls identify a path and a filament. The image and GIF commands send the selected sketch and its description to OpenAI. The locally rendered ink GIF and the built-in circuit use the original Pencil strokes. The saved visuals menu lets you replay previous results on the same page. [Watch the original iPad export](examples/circuit.mp4) or [preview the GIF](examples/circuit.gif).

Narrated MP4 export places captions beneath the action. It uses the system English voice, with an English Flite voice on the workspace server as a fallback. The circuit lesson includes its narration for offline teaching. Generated media is saved with the page and can replay offline.

## How the backend works

| Part | What it owns |
| --- | --- |
| iPad | Original Pencil data, PDFs, media, drafts, page position, library membership, and a Keychain credential for the workspace. A project enters sync when the teacher chooses **Share project**. |
| HTTPS API | Authenticates the owner and both OAuth clients. Checks project access, exposes MCP, and handles generation requests. The API and its rules live in `server/`. |
| Project store | Holds one canonical record per item, project memberships, revisions, preserved conflicts, messages, grants, media chunks, and spending reservations. The hosted option uses the owner's Convex account. Docker Compose runs PostgreSQL on the owner's machine. |
| Worker | Claims human-approved tasks, records the team selected at assignment time, calls the two model providers, and posts each result. A reviewed result can update its linked page. |
| Browser | Lets the owner select models, inspect provider availability, read project messages, assign work, review conflicting edits, and revoke chat grants. |

The iPad and the two chat clients connect independently to HTTPS. Closing the iPad leaves the remote workspace available. The publisher controls the API source, deployment, secrets, and backups. Clerk is optional for a future multi-user deployment. This release has one human owner and project-scoped agent grants.

## Run your own server

Install Docker with Compose. From a fresh checkout:

```sh
git clone https://github.com/BuildThingsThatBuildthings/goodest-notes.git
cd goodest-notes
umask 077
cp .env.example .env
openssl rand -hex 32
openssl rand -hex 32
```

Put one generated value in `OWNER_TOKEN` and the other in `POSTGRES_PASSWORD` in `.env`. Use a URL-safe database password. Set `PUBLIC_URL` to your HTTPS origin when deploying. Add dedicated `OPENAI_API_KEY` and `ANTHROPIC_API_KEY` values to enable paid assignments and OpenAI drawing generation. Protocol collaboration and local ink animation work independently of those two keys.

```sh
docker compose up --build -d
curl -fsS http://127.0.0.1:8080/health
```

Open the local web page and enter the owner key. For external chat connectors, point a DNS name at your host and use a TLS reverse proxy to forward that origin to port 8080. For example, a Caddy instance on the same host can serve:

```caddyfile
notes.example.org {
    reverse_proxy 127.0.0.1:8080
}
```

The database port stays inside Compose. The app creates its tables at startup. Keep the database volume and private environment file when updating. In the iPad app, open **Agent settings**, enter the HTTPS origin and owner key, and connect. Open a project, choose **Conversation**, then **Share project**. The owner can download a remote project from Agent settings on another iPad.

### Hosted deployment with Convex

Create a dedicated Convex project and deploy this repository's `convex/` directory with the Convex CLI. Set a long random `WORKSPACE_SERVICE_KEY` on Convex. Deploy `public/` and `netlify/functions/` using the provided Netlify configuration. Set the same service key, the Convex HTTP action origin ending in `.convex.site` as `CONVEX_STATE_URL`, the public HTTPS origin as `PUBLIC_URL`, and the owner credential as `OWNER_TOKEN` on the API host. Provider keys belong on that API host.

The public Convex HTTP action checks the service credential. Storage mutations are internal. Ordinary MCP requests pass through the API's OAuth and project checks. The scheduled function processes one worker stage per invocation. Self-hosters can also operate a Convex instance and point the same API at its HTTP origin.

## Connect ChatGPT and Claude

Share a project from the iPad and copy its project ID. In each chat client's custom connector settings, enter the public HTTPS origin followed by `/mcp`, choose OAuth, and use automatic client registration when offered. For manual setup use the client ID `chatgpt` or `claude` respectively. These are public PKCE clients. During consent, enter your owner key and the project ID **on your Goodest Notes origin**. Configure `CHATGPT_REDIRECT_URI` if ChatGPT shows a different callback for your workspace. Each grant can be revoked from the web workspace. For a classroom iPad that only needs one project, an authenticated owner can POST a project UUID to `/v1/device`. Its revocable 30-day device credential supports reading that project, posting messages, and changing its page text. Rate settings, paid work, other projects, and new attachments require the owner. A trusted administrator may transfer that scoped JSON response to the app's Application Support/GoodestNotesDevice.json file. The app verifies the scope, saves the token to Keychain, removes the transfer file, and downloads the project. An existing local-network Blockbook bridge remains available for nearby access.

Ask one chat to post a request linked to a page. Ask the other chat to read it, edit the named record using its revision, and reply. Then ask the first chat to read both the reply and the new revision. The tools include `list_projects`, `read_space`, `read_asset`, `read_conversation`, `post_message`, `edit_note`, and `assign_task`. Reuse the request ID when retrying a mutation. A stale edit is preserved for owner review.

## Model selection and spending

**Claude Opus 5.5** is the initial main agent. Pick a different main agent in Agent settings whenever needed. Existing tasks show their original team. A human assignment starts a run. Assignments proposed through a chat connector wait for owner confirmation. A provider failure pauses the run and retains its previous stages.

For a Netlify deployment, save dedicated OpenAI and Anthropic keys in the site's environment variables as `OPENAI_API_KEY` and `ANTHROPIC_API_KEY`. Give them the Functions scope and Production context, then redeploy. For Compose, save the keys in the server's private `.env` and run `docker compose up -d` to reload the web and worker services. Open **Agent settings** and check which model IDs each provider makes available to your account. The chat connectors authorize independently from these API keys.

Each provider has a separate $75 calendar-month limit in UTC. The service reserves a maximum estimate transactionally before calling a provider. Uncertain delivery retains the reservation. The workspace reports spent, reserved and available dollars. These limits apply to calls made through Goodest Notes with its dedicated keys. Hosting and chat subscription use are billed by their respective services.

## Back up and restore

Back up the iPad's application data before an update. Preserve the entire Application Support/Blockbook directory, including its manifest, drawing files, PDFs and Assets subdirectory. Use a separate device container or directory when rehearsing a restore.

For the self-hosted server, back up PostgreSQL and store the environment file separately in a secure location. A project database backup includes messages, references, binary attachment chunks, and cached generation results.

```sh
docker compose exec -T db pg_dump -U goodest -Fc goodest > goodest-backup.dump
docker compose exec -T db createdb -U goodest goodest_restore
docker compose exec -T db pg_restore -U goodest -d goodest_restore < goodest-backup.dump
```

For a Convex workspace, run `npx convex export --prod --include-file-storage --path workspace-backup.zip`. Rehearse `npx convex import --deployment <empty-restore-deployment> workspace-backup.zip` on a dedicated empty deployment. To move the hosted workspace to your own PostgreSQL server, unpack the export into a private directory, configure DATABASE_URL for a new empty database, then run `node scripts/restore-convex.mjs /path/to/extracted-backup`. The import runs in one transaction, verifies attachment checksums, preserves membership and replies, and pauses work that was in flight. OAuth access tokens stay hashed. Reconfigure backend-only secrets independently. Keep backups outside this repository.

## Optional private project catalog

Export a local JSON array, or an object with a `projects` array, from the catalog you control. Each entry needs a stable `projectSlug`, `slug`, or `id`, and a `title` or `name`. Run `node --env-file=.env scripts/import-catalog.mjs /path/to/private-catalog.json`. The adapter derives the same UUID on every import. It reads the source file and sends only the stable ID and project title to the private workspace.

## Verification

Run `npm ci` and `npm test` with Node 22 or later. Supply `TEST_DATABASE_URL` for PostgreSQL integration coverage. The tests create and drop an isolated random schema. To exercise a running HTTPS deployment, run `node --env-file=.env scripts/check-workspace.mjs`. This creates a clearly labeled example project, exchanges two independent OAuth grants, performs page-linked edits and replies, and revokes both temporary grants.

Run the Blockbook unit test scheme on an iPad or Mac Catalyst. The ClassroomUITests target exercises the native iPad interface with an isolated library. The native circuit test checks original ink, the GIF loop boundary, and audio and video tracks. Final classroom acceptance also requires a live Pencil session, external-display playback, and both signed-in chat clients.

## License

Goodest Notes source and original example assets use the MIT license. Dependencies retain their own licenses. Flite and its bundled voices carry the notices distributed with `@echogarden/flite-wasi`.
