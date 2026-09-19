# APM Help Windows PIN rollout

## Release gate

1. Merge the rollout commit on green CI.
2. Push a `teale-YYYY.MM.DD.HHMM` tag from the exact green commit. The Windows workflow must publish `Teale.exe` and `checksums.txt` on that release.
3. Verify the release asset checksum and confirm the installer embeds the same `teale-node.exe` and `teale-tray.exe` commit.
4. Use the direct `Teale.exe` asset URL. Do not send `/releases/latest`, which can resolve to a Mac-only release.
5. On a disposable authenticated test node, confirm `teale-node pin create <temporary-name>` reaches the gateway create route instead of returning 404, then delete the temporary PIN. The September 19 shipped CLI was stale and failed this check; current source maps local `/v1/app/pins/create` to gateway `POST /v1/pins`.
6. Until Authenticode is enabled, state plainly that Windows shows Unknown publisher and requires **More info -> Run anyway**, then UAC approval.

## One-machine canary

Choose a staff-owned Windows 10/11 x64 laptop with at least 16 GB RAM, 10 GB free disk, administrator access, AC power, and outbound HTTPS/WSS access to GitHub, model hosting, gateway.teale.com, and relay.teale.com.

Keep the APM join PIN out of chat, tickets, logs, and command transcripts. Fleet obtains it from Taylor's live PIN admin surface and enters it locally.

### Fresh install and enrollment

1. Record existing Teale services, processes, config, data, and model directories. Use a machine with no prior Teale identity for the first canary.
2. Run the verified installer locally as administrator:
   ```powershell
   .\Teale.exe /PINCODE=<enter-locally> /LOG=C:\Teale\logs\installer-canary.log
   ```
3. Confirm exactly one `TealeNode` service and one per-user `teale-tray.exe` process, with the leaf tray icon.
4. Confirm `C:\Teale\config\teale-node.toml` has a `[pin]` join code configured without printing its value.
5. Confirm the gateway shows one pending device under the expected APM PIN. Taylor/admin approves that exact device id.
6. Confirm the node changes from pending to active, receives its netmap, and remains outside the default public-supply lane.

### Model and employee-lane proof

1. Apply the APM PIN's desired model policy or load the approved model. Confirm download, checksum, load, `/health`, and active model status.
2. Send one bounded test request authenticated to the APM PIN lane.
3. Require dispatch evidence naming the canary employee node and the APM PIN. Confirm response success, usage accounting, and no appearance in the public catalog/default lane.
4. Kill/rework rule: any public-lane eligibility, unapproved node id, missing accounting, or fallback that hides an employee-lane miss stops rollout.

### Reboot and upgrade

1. Reboot. Confirm the service starts once, the tray starts once, PIN membership remains active, the node identity is unchanged, and the model returns healthy without re-enrollment.
2. Publish a canary rebuild (or use the next green build). Confirm the login-time updater detects only `teale-*` releases containing `Teale.exe` and opens the correct asset.
3. Install over top. Confirm identity/model preservation, one service/tray, active PIN membership, and a second employee-lane request.

## Rollout gate

Proceed beyond one machine only after every step passes and telemetry is clean for one workday. Batch the next 5 machines, then 20%, then the remainder. Stop on SmartScreen/help-desk friction above 10%, install failure above 2%, any duplicate process, any identity reset, or any employee node entering the default lane.
