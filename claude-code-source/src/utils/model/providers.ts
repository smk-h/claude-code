import type { AnalyticsMetadata_I_VERIFIED_THIS_IS_NOT_CODE_OR_FILEPATHS } from '../../services/analytics/index.js'
import { isEnvTruthy } from '../envUtils.js'

export type APIProvider = 'firstParty' | 'bedrock' | 'vertex' | 'foundry' | 'openai' | 'cnb'

/**
 * Build the CNB AI base URL from environment variables.
 * Mirrors the logic from open-code/executor.ts:
 *   - ACC_PRODUCT_CONFIG_V2 set → {endpoint}/{slug}/-/ai-ide/v2/
 *   - otherwise                 → {endpoint}/{slug}/-/ai/
 *
 * Returns empty string when the required env vars are missing.
 */
export function getCnbAiBaseUrl(): string {
  const cnbApiEndpoint = process.env.CNB_API_ENDPOINT
  const cnbRepoSlug = process.env.CNB_REPO_SLUG
  if (!cnbApiEndpoint || !cnbRepoSlug) return ''

  if (process.env.ACC_PRODUCT_CONFIG_V2) {
    return `${cnbApiEndpoint}/${cnbRepoSlug}/-/ai-ide/v2/`
  }
  return `${cnbApiEndpoint}/${cnbRepoSlug}/-/ai/`
}

export function getAPIProvider(): APIProvider {
  return isEnvTruthy(process.env.CLAUDE_CODE_USE_CNB)
    ? 'cnb'
    : isEnvTruthy(process.env.CLAUDE_CODE_USE_OPENAI)
      ? 'openai'
      : isEnvTruthy(process.env.CLAUDE_CODE_USE_BEDROCK)
        ? 'bedrock'
        : isEnvTruthy(process.env.CLAUDE_CODE_USE_VERTEX)
          ? 'vertex'
          : isEnvTruthy(process.env.CLAUDE_CODE_USE_FOUNDRY)
            ? 'foundry'
            : 'firstParty'
}

export function getAPIProviderForStatsig(): AnalyticsMetadata_I_VERIFIED_THIS_IS_NOT_CODE_OR_FILEPATHS {
  return getAPIProvider() as AnalyticsMetadata_I_VERIFIED_THIS_IS_NOT_CODE_OR_FILEPATHS
}

/**
 * Check if ANTHROPIC_BASE_URL is a first-party Anthropic API URL.
 * Returns true if not set (default API) or points to api.anthropic.com
 * (or api-staging.anthropic.com for ant users).
 */
export function isFirstPartyAnthropicBaseUrl(): boolean {
  // OpenAI-compatible / CNB modes are never a first-party Anthropic URL
  if (isEnvTruthy(process.env.CLAUDE_CODE_USE_OPENAI) || isEnvTruthy(process.env.CLAUDE_CODE_USE_CNB)) {
    return false
  }
  const baseUrl = process.env.ANTHROPIC_BASE_URL
  if (!baseUrl) {
    return true
  }
  try {
    const host = new URL(baseUrl).host
    const allowedHosts = ['api.anthropic.com']
    if (process.env.USER_TYPE === 'ant') {
      allowedHosts.push('api-staging.anthropic.com')
    }
    return allowedHosts.includes(host)
  } catch {
    return false
  }
}
