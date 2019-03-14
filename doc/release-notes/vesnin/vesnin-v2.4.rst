Release Notes for VESNIN OpenPOWER Firmware v2.4
================================================

This is update 4 to v2 LTS release of OpenPOWER Firmware for revision B
of VESNIN server.

The following changes have been made to the VESNIN OpenPOWER Firmware
since update 3 (v2.3):

VESNIN-specific changes
-----------------------

* Add support for kdump by SRESET signal from BMC.

* Add temperature sensor support for CPU cores.

* Add OEM LUN support for extended sensor inventory:
  Move all 'functional' sensors to IPMI LUN 1,
  leave temperature sensors in LUN 0. This allows for
  overcoming the IPMI limitation on the number of
  sensors.

* Disable hidden error logs in production.

* Remove unused temperature sensor ID for CPU cores.

* Renumber DIMM FRU names:
  FRU names of DIMMs are now equal to their names inside eSEL.

* Renumber membuf FRU names:
  FRU names of memory buffers are now equal to their names inside eSEL.

* Fix ``fwts`` failures. Device tree now conatains ``open-power`` attribute
  inside ``ibm,firmware-versions`` node, has proper ``#address-cells``
  and ``#size-cells`` attributes in ``vpd`` and ``vpd/processor`` nodes,
  as well as correct ``reg`` attributes in ``vpd/processor/cpu`` and
  ``vpd/dimm`` nodes.

* Handle 'unsupported' status for DCMI messages. DCMI Power management
  is not supported for VESNIN and that is now reported by BMC. React
  properly to those reports.

* Add OCC debug commands handling: support for getting OCC logs.

Generic/upstream changes
------------------------

This release update is based on upstream OpenPOWER Firmware version 2.2.
The release notes for it can be found in upstream repository at
https://github.com/open-power/op-build/blob/master/doc/release-notes/v2.2.rst

Please note that the changes listed there are generic and may not neccessarily
be applicable to VESNIN.
