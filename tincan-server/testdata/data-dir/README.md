Sample runtime data for `tincan-server`.

This directory mirrors the server's expected `--data-dir` layout:

- `config/config.json`
- `config/agent_profiles.json`
- `config/agent_backends.json`

The server does not read these files automatically. They are checked in as
examples and test fixtures, and can be used explicitly with:

```sh
go run . --data-dir ./testdata/data-dir
```

If you use them on another machine, update the working directories and backend
options to match your local environment.
