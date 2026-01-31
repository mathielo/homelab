# WiFi & Network setup

For security and traffic optimization, the network is subdivided in separate Virtual LANs (VLANs), each with their own purpose and level of access.

The access points provide different WiFi networks, and each of them connect directly to their respective VLAN:

| ID  | Name    | WiFi SSID  | Bands (GHz) | SSID Broadcast | Inter-VLAN access | Purpose                                         |
| --- | ------- | ---------- | ----------- | -------------- | ----------------- | ----------------------------------------------- |
| 10  | Trusted | 221B       | 2.4 / 5 / 6 | Yes            | Media + IoT       | Trusted devices (PCs, phones)                   |
| 20  | Media   | 221B Media | 2.4 / 5     | No             | None              | Media playing devices (TVs, speakers)           |
| 30  | IoT     | 221B IoT   | 2.4         | No             | None              | All IoT devices (lights, robot vacuum, sensors) |
| 40  | Guest   | 221B Guest | 5           | Yes            | None              | Friends and visitors                            |

All VLANs have internet access (some might have speed limits established e.g. Guest network). Only devices in the Trusted VLAN can access devices in other VLANs; otherwise devices have access limited to the VLAN in which they reside.
