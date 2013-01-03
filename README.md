Sync a directory
----------------

```sh
publisssh ./local-dir bucket/remote-dir
```

Older files are replaced. Replace newer ones with `--force` or `-f`.

Clean up (delete remote orphans) with `--cleanup` or `-c`.

Simulate changes with `--simulate` or `-x`.

AWS keys are `--key` (`-k`) and `--secret` (`-s`), otherwise it'll use the `AMAZON_ACCESS_KEY_ID` and `AMAZON_SECRET_ACCESS_KEY` environment variables.

Config file
-----------

Configuration can be stored in `publisssh-config.json`, `.js`, or `.coffee`.

E.g.:

```coffee
module.exports =
  local: 'public'
  remote: 'www.example.com'
  key: process.env.ALT_AMAZON_ACCESS_KEY_ID
  secret: process.env.ALT_AMAZON_SECRET_ACCESS_KEY
  cleanup: true
```
