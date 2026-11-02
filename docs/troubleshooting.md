# Troubleshooting

Start with the logs, from the instance's folder:

```shell
docker compose ps
docker compose logs dss | grep -E '^\[[-!]\]'
```

## Container start

| Message or symptom | Cause | Fix |
|---|---|---|
| `[-] This volume holds DSS X data, but this image runs DSS Y` | The instance's base image changed | Restore `DSS_BASE_IMAGE`, use another instance, or `docker compose down --volumes` to start fresh. See [Instances](instances.md#change-the-dss-version) |
| `[-] DSS license file ... is not valid JSON` | Damaged or wrong file | Replace `license/license.json` |
| `[-] DSS license path ... is not a readable file` | A folder, or not readable by uid 1000 | See [License on Linux](license.md#linux-hosts) |
| Container restarts, then stops | Any `[-]` error: Docker retries three times | Read the first `[-]` line |
| `starting` for several minutes | First start: DSS is being installed | Wait; follow `docker compose logs -f dss` |
| `port is already allocated` | Another instance or program uses the port | Set another `DSS_HOST_PORT` in the instance's `.env`. See [Host port](instances.md#host-port) |
| DSS reports the license as not validly signed | Entered with `dsscli set-license`, which garbles non-ASCII characters | Use `license/license.json`. See [License](license.md#why-not-dsscli-set-license) |

## Build

| Message | Cause | Fix |
|---|---|---|
| `DSS_BASE_IMAGE is ..., but the image contains DSS ...` | The digest belongs to another tag | Get the tag's digest with `docker buildx imagetools inspect`, or remove the digest |
| `[-] Cannot download ...; check that version ... exists on Maven Central` | Wrong driver version | Check the version on Maven Central, or set it to `""` |
| `[-] SHA-256 mismatch for ...` | Corrupted download | Run `docker compose up -d` again |
| `/home/dataiku/run.sh does not contain the expected line` | A new base image changed its startup script | Update the line in `image/Dockerfile` after checking the new `run.sh` |

## Inspect an instance

```shell
docker compose exec dss bash                          # shell in the container
docker compose exec dss ls /home/dataiku/dss/lib/jdbc # installed drivers
docker volume inspect <name>_dss-data                 # data volume
```

In Git Bash, prefix commands that contain container paths with
`MSYS_NO_PATHCONV=1`, or Git Bash rewrites them into Windows paths.
