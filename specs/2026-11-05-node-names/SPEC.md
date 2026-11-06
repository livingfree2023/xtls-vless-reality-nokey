# Node names

Before connection output, ask for a base name via /dev/tty (safe for curl|bash); Enter/EOF/no terminal defaults to hostname. Fetch https://ipinfo.io/json once with bounded timeout, validate country as two uppercase ASCII letters, generate Unicode flag for any country. Failure omits country prefix without blocking installation. Do not change system hostname or service config.

Names: flag + country + '.' + base + protocol + family. Reality uses .VR, classic AES SS uses .SS, SS2022 uses .SS2022 to avoid duplicate Clash names. IPv4 has no family suffix; IPv6 appends .V6. Example 🇭🇰HK.WAWO200.SS.V6. Preserve original SS ciphers, ports and warning. URI-encode fragments; quote YAML names for arbitrary input. Reject control characters in names.

Research: real HTTPS ipinfo.io/json probe returned a valid country (US). Only country consumed, no response saved. Unit: all sample flags, invalid country, default/custom names, failed lookup, URI/YAML safety. Module: names agree between URL/Clash for both families and SS ciphers; TTY prompt tests. Integration: live country probe completed; no VPS install. Run required offline suites.
