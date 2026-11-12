# Data handling

Dumptruck processes the folders you select on your Mac. Its reports, receipts,
and MHL records can contain file names, paths, timestamps, machine and user
identifiers, and media thumbnails or metadata. Destination copies and exported
reports may disclose these details to anyone who receives them. Local job
history and settings also retain information about jobs and selected paths.

The app asks GitHub's public API once a day whether a newer release exists.
The request names no user, job, drive or file; GitHub sees the connection's
IP address, as any website does. Nothing is downloaded until you click
Download. Settings > Display turns the check off.

Remote webhook notifications are optional. When enabled, the app sends the
configured HTTPS endpoint a job ID, job label, verdict, phase, verification
flags, timestamps, and aggregate counts. The job label may contain client or
production information. The receiving service also sees the connection's IP
address. Media files, file lists, and source or destination paths are not
fields in the webhook payload.

The app stores webhook bearer credentials in the macOS Keychain. The recipient
controls retention and access to received notifications. Use an endpoint you
are authorized to share job information with. Remove confidential information
before attaching reports, logs, or screenshots to a public issue.
