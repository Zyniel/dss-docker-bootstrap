# License

## Install a license

```shell
cp /path/to/license.json license/license.json
cd instances/<name>
docker compose restart dss
```

- `license/` is shared by all instances, mounted read-only at
  `/home/dataiku/license`.
- At each start, the license is copied to the data directory
  (`config/license.json`) when it differs, then DSS starts with it.
- It is ignored by Git, and outside the build context: it never ends up in a
  commit or an image.

## Behavior

| Situation | Result |
|---|---|
| `license/license.json` present | Installed; replaces any license entered in the DSS UI |
| Absent, a license already installed | Kept, with a warning in the logs |
| Absent, no license installed | DSS runs in its default free mode, with a warning |
| Unreadable, or not valid JSON | The container stops before changing anything |

The container only checks that the file is valid JSON. DSS checks the
signature and the expiry date at startup.

To remove an installed license, take it out of `license/`, then delete it from
the data directory:

```shell
docker compose exec dss rm /home/dataiku/dss/config/license.json
docker compose restart dss
```

In Git Bash, prefix the first command with `MSYS_NO_PATHCONV=1`.

## Why not `dsscli set-license`

- It needs a running DSS, then a restart.
- It sends the file without a charset: DSS misreads non-ASCII characters, such
  as `ç` in a name, and rejects a valid license with "Your license is not
  validly signed".

Copying the file before DSS starts avoids both.

## Linux hosts

The bind mount keeps the host file's owner and permissions. The container runs
as `dataiku` (uid 1000), which must be able to read the file:

```shell
chmod 600 license/license.json
sudo chown 1000 license/license.json
```

Docker Desktop does not need this.
