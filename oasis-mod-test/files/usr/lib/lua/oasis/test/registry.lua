return {
    {
        suite = "portable",
        module = "oasis.test.spec.response_framer",
        description = "Pure Lua response framing and size limits",
        default = true,
    },
    {
        suite = "portable",
        module = "oasis.test.spec.security_guard",
        description = "Pure Lua input validation contracts",
        default = true,
    },
    {
        suite = "unit",
        module = "oasis.test.spec.schema",
        description = "Unified chat schema and fail-closed sanitization",
        default = true,
    },
    {
        suite = "unit",
        module = "oasis.test.spec.chat_error",
        description = "Structured chat error classification and formatting",
        default = true,
    },
    {
        suite = "provider",
        module = "oasis.test.spec.provider_framing",
        description = "Provider transport framing contracts",
        default = true,
    },
    {
        suite = "provider",
        module = "oasis.test.spec.provider_user_only",
        description = "Provider tool-output privacy boundary",
        default = true,
    },
    {
        suite = "provider",
        module = "oasis.test.spec.provider_request",
        description = "Provider request construction and title controls",
        default = true,
    },
    {
        suite = "device",
        module = "oasis.test.spec.installation",
        description = "Read-only installed package smoke tests",
        default = false,
    },
}
