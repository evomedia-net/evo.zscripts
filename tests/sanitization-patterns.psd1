<#
    Patterns the PUBLIC repo must never contain.

    Extracted from Sanitization.Tests.ps1 so that the test here and the
    publisher in the private tree read ONE list instead of keeping two.
    They had two, and they disagreed: the publisher's scan looked only for
    secrets - keys, private-key blocks, ssh targets - while these rules are
    about IDENTITY: internal project names, product domains, private-only
    script names, operator paths.

    So the publisher reported "clean" on files this suite rejects, and would
    have published a tree that fails the public repo's own tests
    (evo.scripts#106). One list, and that cannot drift apart again.

    A denylist proves the absence of KNOWN patterns, not the absence of
    secrets. It is a regression net for a specific recurring mistake, not a
    substitute for reading what you publish. Add a pattern whenever a new
    private identifier appears; a stale entry costs nothing.

    Kept narrow on purpose: "evomedia.net" alone is legitimate here - the
    attribution header and the repo URL both carry it - so only the drive
    path and specific internal hosts are matched.
#>
@{
    Denied = @(
        @{ Name = 'private project name';   Pattern = '\b(EvoCivilCode|EvoPlatform|DocketMail|SmartPlant\w*|ProvenSheet|evoehs|evoproven|evoaicc|evolocate|evoplatform)\b' }
        @{ Name = 'private product domain'; Pattern = '\b(smartplantehs\.com|provensheet\.com|evoehs\.com|civilcode\.evomedia\.net|dashboard\.evomedia\.net|webmail\.evomedia\.net|mail-admin\.evomedia\.net|docketmail\.evomedia\.net|cardiff\.evomedia\.net|platform\.evomedia\.net|ai\.evomedia\.net|git\.evomedia\.net|analytics\.evomedia\.net)\b' }
        @{ Name = 'private-only script';    Pattern = '\b(register_civilcode|register_docketmail|sp_seed_demo_prod|zpublish_stats|zcoverage|zmerge|zpull|zresume|swag_set_owner|provision_demo|apply_platform_config_fixes)\b' }
        @{ Name = 'local drive path';       Pattern = '[A-Za-z]:\\\\?evomedia\.net' }
        @{ Name = 'operator home path';     Pattern = '/home/ubuntu/' }
        @{ Name = 'real pem key name';      Pattern = 'evomedia-prod\.pem' }
        # RFC 5737 reserves 203.0.113.0/24 for documentation - that one is the
        # correct placeholder and must stay allowed, as are loopback and the
        # private ranges. Anything else that looks like a public IPv4 literal is
        # suspect.
        #
        # The boundaries are [\d.] rather than \d on purpose: this toolkit's own
        # 5-segment version (v1.0.0.0.14) contains "0.0.0.14", which a plain
        # digit boundary happily reads as an address. Refusing a match that
        # touches another dot rules out every version string without weakening
        # detection of a real address, which is always delimited by whitespace
        # or quotes.
        @{ Name = 'non-documentation IP';   Pattern = '(?<![\d.])(?!203\.0\.113\.)(?!127\.0\.0\.1)(?!0\.0\.0\.0)(?!255\.)(?!10\.)(?!192\.168\.)(?!172\.(1[6-9]|2\d|3[01])\.)\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}(?![\d.])' }

    )
}
