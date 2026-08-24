# Driver seed (OOBD driver store)

`models.seed.json` lists the vendor models the driver store is provisioned for. On
Start Imaging Services the sidecar creates `<library>/Drivers/<Vendor>/<Model>/`
folders from this seed and writes `index.json` beside them.

Store vendor packs as downloaded (`.cab`, `.exe`, `.7z`, `.zip`) or as an extracted
INF tree - the deploy client (startnet.cmd) matches on SMBIOS manufacturer/product,
then `Drivers/aliases.txt`, then `Drivers/_default`, expands the pack with the
injected 7z/expand, and `dism /Add-Driver`s the result into the applied image.

Populate packs from the Drivers tab (vendor SCCM catalogs) or drop files into the
store folders by hand.
