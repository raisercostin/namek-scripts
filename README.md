# namek-scripts
Utility scripts for windows/linux.

## Linux utility functions
Utility functions and sane settings by including `.bootstrap`.

- Create your script `./myscript`:

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
- Execute with `./myscript sample1`

## Windows scripts
- `windows/network.ps1` - Disable Random Hardware Address Option in Windows 10 by adding the hardware address to registry
  - from https://community.spiceworks.com/scripts/show/4484-disable-random-hardware-address-option-in-windows-10
  - run it with admin rights `sudo powershell`