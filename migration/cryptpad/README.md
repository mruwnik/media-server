# CryptPad Migration

## Files

- `config.js` - CryptPad configuration

## Data Location

All CryptPad data lives in `/media/data/cryptpad/`:
- `datastore/` - Encrypted documents
- `block/` - User blocks
- `blob/` - Binary blobs
- `data/` - Misc data
- `config/` - Configuration

## Current Setup

- Main domain: docs.ahiru.pl
- Sandbox domain: secure.docs.ahiru.pl (required for security)
- Running via Node.js with nvm

## NixOS Implementation

```nix
services.cryptpad = {
  enable = true;
  settings = {
    httpUnsafeOrigin = "https://docs.ahiru.pl";
    httpSafeOrigin = "https://secure.docs.ahiru.pl";

    # Data directories - point to existing data
    filePath = "/media/data/cryptpad/datastore";
    archivePath = "/media/data/cryptpad/data/archive";
    pinPath = "/media/data/cryptpad/data/pins";
    taskPath = "/media/data/cryptpad/data/tasks";
    blockPath = "/media/data/cryptpad/block";
    blobPath = "/media/data/cryptpad/blob";
    blobStagingPath = "/media/data/cryptpad/data/blobstage";
  };
};
```

## SSL Requirements

CryptPad requires BOTH domains on the same certificate:
- docs.ahiru.pl
- secure.docs.ahiru.pl

```nix
security.acme.certs."docs.ahiru.pl" = {
  extraDomainNames = [ "secure.docs.ahiru.pl" ];
};
```

## Notes

- CryptPad stores everything encrypted - the server can't read documents
- Existing data should work with new install if paths are correct
- User accounts are stored in the datastore
