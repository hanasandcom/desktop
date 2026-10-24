import Foundation

enum NativeDeveloperOnboardingContent {
    static let typeGenerationCommand = "npx openapi-typescript https://hanasand.com/api/openapi/ti -o src/hanasand-api.d.ts"
    static let clientInstallCommand = "npm install openapi-fetch"
    static let paginationGuidance = "Start at page=1. Limit accepts up to 100 records and defaults to 50. Read pagination.totalPages and keep requesting pagination.nextPage until it is null."
    static let typedClientExample = """
    import createClient from 'openapi-fetch'
    import type { paths } from './hanasand-api'

    const api = createClient<paths>({
      baseUrl: 'https://api.hanasand.com/api/v1',
      headers: { 'X-API-Key': process.env.HANASAND_API_KEY! }
    })

    const { data, error } = await api.GET('/actors', {
      params: { query: { page: 1, limit: 20 } }
    })
    if (error) throw new Error(error.error.message)
    """
}
