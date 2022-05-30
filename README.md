# namek-scripts

Utility bash functions. And sane settings.

## Usage

- Create your script `./myscript.sh`:

  ```bash
  #!/bin/bash
  source .bootstrap
  function sample1Command() {
    echo "$ident ${green}Sample executed.${reset}"
  }
  gitUpdate . "https://${credentials}github.com/raisercostin/backupdo.git"

  commandMain
  ```

- Copy `samples/.bootstrap` to `./.bootstrap`
- Execute with `./myscript.sh sample1`
