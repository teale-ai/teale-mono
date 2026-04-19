# Set Up a Private Network

Create a Private TealeNet (PTN) to run inference within a trusted group --- your company, team, or household --- with fixed pricing, priority routing, and known participants.

---

## Prerequisites

- Teale installed on all participating Macs
- WAN networking enabled on all nodes (`teale config set wan_enabled true`)
- At least two nodes (one admin/provider, one consumer)

## Overview

A PTN is a private overlay network within TealeNet. Members are authenticated via CA-signed certificates, and PTN traffic receives 70% WFQ (Weighted Fair Queuing) priority over public traffic. See [Private TealeNet](../concepts/private-tealenet.md) for the full design.

## Step 1: Create the PTN

On the machine that will be the first admin:

```bash
teale ptn create "Acme Corp"
```

This returns a PTN ID (a unique identifier for your network). Save it --- you will need it for all subsequent commands.

```
PTN created: ptn_a1b2c3d4e5f6
You are the founding admin.
CA keypair stored in Keychain.
```

## Step 2: Generate an invite

Create an invite code to share with prospective members:

```bash
teale ptn invite ptn_a1b2c3d4e5f6
```

This outputs a single-use invite code. The invite allows a node to request membership but does not grant access on its own --- you must also issue a certificate (Step 4).

## Step 3: Share the invite code

Send the invite code to the person joining your PTN. Use a secure channel (encrypted messaging, in-person, etc.). The invite code is sensitive --- anyone who has it can request to join.

## Step 4: Member requests to join

On the member's machine, they use the invite code to request membership:

```bash
teale ptn join <invite-code>
```

This registers the node with the PTN and generates a certificate signing request. The admin is notified of the pending request.

## Step 5: Issue a certificate

Back on the admin's machine, issue a signed certificate to the new member:

```bash
teale ptn issue-cert ptn_a1b2c3d4e5f6 <nodeID> --role provider
```

Available roles:

| Role       | Description                                                    |
|------------|----------------------------------------------------------------|
| `admin`    | Can issue/revoke certs, manage membership, promote other admins |
| `provider` | Serves inference requests within the PTN                        |
| `consumer` | Sends inference requests to PTN providers                       |

A node can hold multiple roles. Most members will be both `provider` and `consumer`.

## Step 6: Promote another admin (optional)

For redundancy, promote a trusted member to admin:

```bash
teale ptn promote-admin ptn_a1b2c3d4e5f6 <nodeID>
```

The new admin needs the CA key to issue certificates. Export and share it securely:

## Step 7: Import CA key (new admin)

On the newly promoted admin's machine:

```bash
teale ptn import-ca-key ptn_a1b2c3d4e5f6 <caKeyHex>
```

The CA key is stored in the system Keychain. With it, the new admin can issue and revoke certificates independently.

## Benefits of a PTN

- **70% WFQ priority.** PTN traffic is prioritized over public network requests on shared nodes.
- **Fixed pricing.** Set predictable per-token rates instead of market-driven pricing.
- **Known participants.** Every member is authenticated by certificate. No anonymous traffic.
- **Data isolation.** Inference requests stay within your PTN members. No data touches public nodes.

## Recovery

If an admin loses access or leaves, the remaining admin(s) can continue operating normally. If all admins are lost, any existing member can initiate recovery:

```bash
teale ptn recover ptn_a1b2c3d4e5f6
```

This creates a new CA from the existing membership roster, requiring consensus from a majority of active members.

---

## Next steps

- [Private TealeNet](../concepts/private-tealenet.md) --- full concept documentation
- [WAN Networking](wan-networking.md) --- how nodes connect across the internet
- [Wallet and Payments](wallet-and-payments.md) --- how billing works within a PTN
