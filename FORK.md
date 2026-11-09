# aroberts/dreame-vacuum

Fork of [Tasshack/dreame-vacuum](https://github.com/Tasshack/dreame-vacuum) (MIT), based on upstream `v2.0.3`.
It runs a Dreame L20 Ultra.

The fork removes the paid Dreame Vacuum Card (DVC) code and carries a few fixes and features from other forks.
Each change below names its source commit, so it can be dropped when upstream ships an equivalent.

## Changes against upstream

### DVC removal

1. **`frontend.py` and its plumbing removed.** Source: yodax/dreame-vacuum `908a927`.
   Upstream's `frontend.py` is obfuscated. It registers a Lovelace resource, checks a licence key against
   `api.tasshack.com`, and runs JavaScript from that server with `eval` in the Home Assistant browser session.
   The commit also removes the DVC key options step, the `CONF_DVC_KEY`, `FRONTEND` and `DVC` constants, the
   one-time card notification, and the `lovelace` after-dependency.
   The fork left out two files from that commit: `dreame/dreame_iot_mqtt_ca.pem` and `scripts/check_mqtt_tls.py`.
   Both belong to yodax's TLS rewrite, and upstream #1919 superseded it.
2. **Dynamic `frontend` import hook removed.** Source: yodax/dreame-vacuum `2191d46`.
   Upstream's `__init__.py` imports `frontend.py` whenever the file exists. A HACS overwrite or a stray copy
   would bring the DVC loader back. With the hook gone, the integration never imports it.
3. **`hacs.json` installs from source.** Source: colmixofficial/dreame-vacuum `fca198a` (`hacs.json` only).
   `zip_release` and `filename` are removed. The upstream `dreame_vacuum.zip` release asset ships `frontend.py`.

Dead `dvc` config-step strings remain in `strings.json` and `translations/*.json`. They are unused and stay
there to keep upstream merges clean. `diagnostics.py` keeps `dvc_key` in its redaction list, because older
config entries may still store one.

Do not run the `install` script. It downloads upstream's release zip, `frontend.py` included.

### Fixes

4. **Stop requesting a map list that has no md5 and is not on the cloud.** Source: Styx85/dreame-vacuum `e1610b7`.
   Some devices report a map list object with an empty md5 that was never uploaded, so every update requested it
   and got a 404. The cloud protocols now record the last file status, and a 404 on an empty-md5 map list stops
   the requests until the property changes. A second behaviour change rides along: a map list change seen while
   the robot runs now queues a request, and the map list is fetched once the robot stops. Before, upstream skipped
   that change.
5. **`hide_segments` merges the hidden rooms of the map it targets.** Fork-local, fixes change 6.
   Change 6 read `hidden_segments` from the current map even when called with another `map_id`.

### Features

6. **Map editing services that keep existing objects.** Source: tiheat/dreame-vacuum `e99a2d6`, without the eight
   `__pycache__/*.pyc` files the commit contained.
   - `vacuum_add_restricted_zone` appends walls, no-go zones and no-mop zones to the current ones.
     Upstream's `vacuum_set_restricted_zone` replaces them all.
   - `vacuum_add_carpet_area` appends carpets. Existing carpets keep their type and tassel settings.
   - `vacuum_remove_map_objects` removes the walls, zones and carpets at given points (default tolerance 150).
     It ignores auto-detected carpets, because the robot only allows ignoring those.
   - `vacuum_hide_segments` hides rooms and keeps the rooms already hidden.
   - `vacuum_split_segments` accepts a drawn path, and finds the room itself when `segment` is omitted.
   - Walls can be given as drawn paths, and each path step becomes a wall.
   - Service forms in `services.yaml`, with English and Portuguese strings.

   Upstream keeps its advanced map services out of `services.yaml` on purpose, because calling them with empty
   fields can remove map objects (see upstream #1826). The services above only add or remove what they are given.

## Considered and not taken

Candidates came from a fork-network survey on 2026-11-09: the 60 most recently pushed forks, all pushed after
2026-05-01.

- **yodax `dbeacc3` (TLS verification rewrite).** Upstream #1919 added certificate, signature and Finished
  verification to `DreameTLSSocket`, which also carries MQTT.
- **savek-cc `a0bc7e8` (retry on a dropped pooled connection).** Upstream v2.0.3 fixed the cause differently,
  by retiring pooled sockets after the server's 10 s keep-alive (`protocol.py`, `sock.keep_alive`).
- **The Google Analytics beacon** that yodax removed in its b25-era branch (`51e0939`). It is absent from v2.0.3.
- **s1mptom Mi Home cloud work** (`0779a31`, `c735dab`, parallel map-object fetch). It is Mi Home only, and
  skips itself on the Dreame cloud.
- **Fixes upstream rejected with reasons or replaced with its own:** savek-cc docked-state, manual-refresh,
  scope-warning-filter and poll-overwrites-push; forming fix-issue-1847/1848/1849/1854/1856; sbvitok
  batch splitting; mrueg's `services.yaml` additions.

## Maintaining

- Keep upstream's line endings. `device.py`, `map.py`, `types.py`, `select.py`, `vacuum.py`,
  `dreame/__init__.py`, `const.py` and `hacs.json` are CRLF upstream. Edits to them must stay CRLF, or every
  upstream merge conflicts.
- After merging a new upstream release, check `custom_components/` for:
  - a reappearing `frontend.py` (delete it);
  - an import of `frontend` in `__init__.py`, `config_flow.py` or `coordinator.py`;
  - new outbound hostnames, `eval`/`exec`, `requests.post`, or base64-encoded URLs;
  - `zip_release` returning to `hacs.json`.
- Drop a change from this list when upstream ships an equivalent.
