# OBD11 VAG Bypass iOS 14

Rootful iOS 14 build focused only on OBD11 VAG.

Version 1.0.1 is a minimal compatibility build: it injects only into OBD11 VAG and uses the direct NSBundle build/version read needed by VAG's update check. The broader CoreFoundation and NSURLSession hooks from the first iOS 14 build were removed to avoid the instant startup crash.

This build is specifically for testing the VAG startup crash before adding any wider hooks back.
