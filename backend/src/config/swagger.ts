/**
 * Basic OpenAPI 3.0 specification for the HomeSync API, served via
 * swagger-ui-express at /api/docs.
 */

import {
  COSMETICS,
  FEED_AMOUNT,
  FEED_COOLDOWN_HOURS,
  PLAY_AMOUNT,
  PLAY_COOLDOWN_HOURS,
} from './economy';

const bearerAuth = [{ bearerAuth: [] }];

// Sourced from the real catalog (config/economy.ts) rather than hardcoded,
// so the docs can't drift from what POST cosmetics/buy actually accepts.
const cosmeticIds = COSMETICS.map((c) => c.id);

/**
 * Optional Idempotency-Key header accepted by every resource-creating POST
 * (ADR-007). Repeating a key replays the stored response with HTTP 200.
 */
const idempotencyKeyHeader = {
  name: 'Idempotency-Key',
  in: 'header',
  required: false,
  description:
    'Optional. One stable UUID per logical operation, reused across retries. ' +
    'A repeat replays the original response with HTTP 200 and creates nothing; ' +
    'a repeat racing the in-flight original may answer 409 (never auto-retry it).',
  schema: { type: 'string' },
};

export const swaggerSpec: Record<string, unknown> = {
  openapi: '3.0.3',
  info: {
    title: 'HomeSync API',
    version: '1.0.0',
    description:
      'REST + realtime API for HomeSync — household tasks and shopping. ' +
      'All responses use the envelope `{ success, data?, error? }`.',
  },
  servers: [{ url: '/api', description: 'API root' }],
  components: {
    securitySchemes: {
      bearerAuth: { type: 'http', scheme: 'bearer', bearerFormat: 'JWT' },
    },
    schemas: {
      Page: {
        type: 'object',
        description:
          'Cursor-paginated page. `nextCursor` is opaque: it encodes the full sort ' +
          'position (not just an id) and must be passed back verbatim. See ADR-008.',
        properties: {
          items: { type: 'array', items: {} },
          nextCursor: {
            type: 'string',
            nullable: true,
            description: 'Opaque base64 cursor for the next page; null when hasMore is false',
          },
          hasMore: { type: 'boolean', description: 'Whether rows exist after this page' },
          total: {
            type: 'integer',
            nullable: true,
            description:
              'Rows matching the filter. Returned only on the first page (no cursor); ' +
              'null on paged requests.',
          },
        },
      },
      Error: {
        type: 'object',
        properties: {
          success: { type: 'boolean', example: false },
          error: { type: 'string' },
        },
      },
      AuthResponse: {
        type: 'object',
        properties: {
          success: { type: 'boolean', example: true },
          data: {
            type: 'object',
            properties: {
              user: { $ref: '#/components/schemas/User' },
              tokens: {
                type: 'object',
                properties: {
                  accessToken: { type: 'string' },
                  refreshToken: { type: 'string' },
                },
              },
            },
          },
        },
      },
      User: {
        type: 'object',
        properties: {
          id: { type: 'string' },
          email: { type: 'string', format: 'email' },
          name: { type: 'string' },
          avatarUrl: { type: 'string', nullable: true },
          households: { type: 'array', items: { type: 'string' } },
        },
      },
      Task: {
        type: 'object',
        properties: {
          id: { type: 'string' },
          householdId: { type: 'string' },
          title: { type: 'string' },
          description: { type: 'string' },
          status: { type: 'string', enum: ['pending', 'completed'] },
          priority: { type: 'string', enum: ['low', 'medium', 'high'] },
          category: {
            type: 'string',
            enum: ['cleaning', 'cooking', 'shopping', 'maintenance', 'other'],
          },
          dueDate: { type: 'string', format: 'date-time', nullable: true },
          isRecurring: { type: 'boolean' },
          parentTaskId: { type: 'string', nullable: true },
          isDeleted: { type: 'boolean' },
          deletedAt: { type: 'string', format: 'date-time', nullable: true },
        },
      },
      ShoppingItem: {
        type: 'object',
        properties: {
          id: { type: 'string' },
          householdId: { type: 'string' },
          name: { type: 'string' },
          quantity: { type: 'number' },
          unit: { type: 'string' },
          category: {
            type: 'string',
            enum: ['fridge', 'pantry', 'cleaning', 'personal', 'other'],
          },
          isPurchased: { type: 'boolean' },
        },
      },
      Pet: {
        type: 'object',
        description:
          "The household's shared pet (PDR-001). hunger/mood are decayed to the " +
          'current time on every read (economy.service.ts computeDecay) — nothing is ' +
          'written back until the next feed/play/adoption.',
        properties: {
          id: { type: 'string' },
          householdId: { type: 'string' },
          species: { type: 'string', enum: ['cat', 'dog'] },
          name: { type: 'string' },
          adoptedAt: { type: 'string', format: 'date-time' },
          adoptedBy: { type: 'string', description: 'User id of the adopting/confirming member' },
          hunger: { type: 'integer', minimum: 0, maximum: 100 },
          mood: { type: 'integer', minimum: 0, maximum: 100 },
          lastFedAt: { type: 'string', format: 'date-time', nullable: true },
          lastPlayedAt: { type: 'string', format: 'date-time', nullable: true },
          cosmetics: {
            type: 'array',
            items: { type: 'string' },
            description: 'Owned cosmetic ids',
          },
          activeCosmetic: { type: 'string', nullable: true },
        },
      },
      AdoptionRequest: {
        type: 'object',
        description:
          'A pending adoption proposal — 2+ member households only. A single-member ' +
          'household never produces one of these: POST .../pet/adopt adopts instantly ' +
          'instead and returns a Pet, not this shape (PDR-001).',
        properties: {
          id: { type: 'string' },
          householdId: { type: 'string' },
          species: { type: 'string', enum: ['cat', 'dog'] },
          name: { type: 'string' },
          requestedBy: { type: 'string', description: 'User id of the proposing member' },
          status: { type: 'string', enum: ['pending'] },
        },
      },
      EconomyTransaction: {
        type: 'object',
        properties: {
          amount: { type: 'integer', description: 'Positive to earn, negative to spend' },
          reason: {
            type: 'string',
            enum: [
              'task_complete',
              'purchase_complete',
              'feed',
              'play',
              'cosmetic_buy',
              'adoption_bonus',
            ],
          },
          refId: { type: 'string', nullable: true },
          createdAt: { type: 'string', format: 'date-time' },
        },
      },
    },
  },
  paths: {
    '/auth/register': {
      post: {
        tags: ['Auth'],
        summary: 'Register a new user',
        requestBody: {
          required: true,
          content: {
            'application/json': {
              schema: {
                type: 'object',
                required: ['email', 'password', 'name'],
                properties: {
                  email: { type: 'string', format: 'email' },
                  password: { type: 'string', minLength: 6 },
                  name: { type: 'string' },
                },
              },
            },
          },
        },
        responses: {
          '201': {
            description: 'Created',
            content: {
              'application/json': { schema: { $ref: '#/components/schemas/AuthResponse' } },
            },
          },
          '400': { description: 'Validation error' },
        },
      },
    },
    '/auth/login': {
      post: {
        tags: ['Auth'],
        summary: 'Log in',
        requestBody: {
          required: true,
          content: {
            'application/json': {
              schema: {
                type: 'object',
                required: ['email', 'password'],
                properties: {
                  email: { type: 'string', format: 'email' },
                  password: { type: 'string' },
                },
              },
            },
          },
        },
        responses: {
          '200': {
            description: 'OK',
            content: {
              'application/json': { schema: { $ref: '#/components/schemas/AuthResponse' } },
            },
          },
          '401': { description: 'Invalid credentials' },
        },
      },
    },
    '/auth/refresh': {
      post: {
        tags: ['Auth'],
        summary: 'Rotate tokens',
        requestBody: {
          required: true,
          content: {
            'application/json': {
              schema: {
                type: 'object',
                required: ['refreshToken'],
                properties: { refreshToken: { type: 'string' } },
              },
            },
          },
        },
        responses: { '200': { description: 'New token pair' }, '401': { description: 'Invalid' } },
      },
    },
    '/auth/logout': {
      post: {
        tags: ['Auth'],
        summary: 'Invalidate a refresh token',
        requestBody: {
          required: true,
          content: {
            'application/json': {
              schema: {
                type: 'object',
                required: ['refreshToken'],
                properties: { refreshToken: { type: 'string' } },
              },
            },
          },
        },
        responses: { '200': { description: 'Logged out' } },
      },
    },
    '/auth/me': {
      get: {
        tags: ['Auth'],
        summary: 'Current user',
        security: bearerAuth,
        responses: { '200': { description: 'OK' }, '401': { description: 'Unauthorized' } },
      },
    },
    '/households': {
      post: {
        tags: ['Households'],
        summary: 'Create a household',
        security: bearerAuth,
        parameters: [idempotencyKeyHeader],
        requestBody: {
          required: true,
          content: {
            'application/json': {
              schema: {
                type: 'object',
                required: ['name'],
                properties: { name: { type: 'string' } },
              },
            },
          },
        },
        responses: { '201': { description: 'Created' } },
      },
    },
    '/households/join': {
      post: {
        tags: ['Households'],
        summary: 'Join a household by invite code',
        security: bearerAuth,
        parameters: [idempotencyKeyHeader],
        requestBody: {
          required: true,
          content: {
            'application/json': {
              schema: {
                type: 'object',
                required: ['inviteCode'],
                properties: { inviteCode: { type: 'string' } },
              },
            },
          },
        },
        responses: { '200': { description: 'Joined' }, '404': { description: 'Invalid code' } },
      },
    },
    '/households/{id}': {
      get: {
        tags: ['Households'],
        summary: 'Get a household (members only)',
        security: bearerAuth,
        parameters: [{ name: 'id', in: 'path', required: true, schema: { type: 'string' } }],
        responses: { '200': { description: 'OK' }, '403': { description: 'Forbidden' } },
      },
    },
    '/households/{householdId}/stats': {
      get: {
        tags: ['Households'],
        summary: 'Household load/completion stats (PDR-007, any member)',
        security: bearerAuth,
        parameters: [
          { name: 'householdId', in: 'path', required: true, schema: { type: 'string' } },
          {
            name: 'period',
            in: 'query',
            required: false,
            description: 'Window for the stats; invalid value responds 400',
            schema: { type: 'string', enum: ['last30days', 'allTime'], default: 'last30days' },
          },
        ],
        responses: {
          '200': {
            description: 'Household stats',
            content: {
              'application/json': {
                schema: {
                  type: 'object',
                  properties: {
                    success: { type: 'boolean' },
                    data: {
                      type: 'object',
                      properties: {
                        totalTasks: { type: 'integer' },
                        completedTasks: { type: 'integer' },
                        completionRate: { type: 'number' },
                        memberStats: {
                          type: 'array',
                          items: {
                            type: 'object',
                            properties: {
                              userId: { type: 'string' },
                              userName: { type: 'string' },
                              avatarUrl: { type: 'string', nullable: true },
                              created: { type: 'integer' },
                              completed: { type: 'integer' },
                            },
                          },
                        },
                        topCompleter: {
                          type: 'object',
                          nullable: true,
                          properties: {
                            userId: { type: 'string' },
                            userName: { type: 'string' },
                            completed: { type: 'integer' },
                          },
                        },
                        period: { type: 'string', enum: ['last30days', 'allTime'] },
                      },
                    },
                  },
                },
              },
            },
          },
          '400': {
            description: 'Invalid period',
            content: { 'application/json': { schema: { $ref: '#/components/schemas/Error' } } },
          },
          '403': { description: 'Not a member of this household' },
          '404': { description: 'Household not found' },
        },
      },
    },
    '/households/{householdId}/tasks': {
      get: {
        tags: ['Tasks'],
        summary: 'List tasks (pending first)',
        security: bearerAuth,
        parameters: [
          { name: 'householdId', in: 'path', required: true, schema: { type: 'string' } },
          {
            name: 'status',
            in: 'query',
            required: false,
            description: 'Filter by status; combines with the cursor',
            schema: { type: 'string', enum: ['pending', 'completed'] },
          },
          {
            name: 'limit',
            in: 'query',
            required: false,
            description: 'Page size; out of range responds 400',
            schema: { type: 'integer', minimum: 1, maximum: 100, default: 50 },
          },
          {
            name: 'cursor',
            in: 'query',
            required: false,
            description: 'Opaque cursor from a previous nextCursor; malformed responds 400',
            schema: { type: 'string' },
          },
          {
            name: 'includeDeleted',
            in: 'query',
            required: false,
            description:
              'When "true" (TD-009), includes soft-deleted tasks in the page instead of excluding them. Used by the trash view.',
            schema: { type: 'boolean', default: false },
          },
        ],
        responses: {
          '200': {
            description: 'One page of tasks',
            content: {
              'application/json': {
                schema: {
                  type: 'object',
                  properties: {
                    success: { type: 'boolean' },
                    data: {
                      allOf: [
                        { $ref: '#/components/schemas/Page' },
                        {
                          type: 'object',
                          properties: {
                            items: {
                              type: 'array',
                              items: { $ref: '#/components/schemas/Task' },
                            },
                          },
                        },
                      ],
                    },
                  },
                },
              },
            },
          },
          '400': {
            description: 'Invalid limit, cursor or status filter',
            content: { 'application/json': { schema: { $ref: '#/components/schemas/Error' } } },
          },
        },
      },
      post: {
        tags: ['Tasks'],
        summary: 'Create a task',
        security: bearerAuth,
        parameters: [
          { name: 'householdId', in: 'path', required: true, schema: { type: 'string' } },
          idempotencyKeyHeader,
        ],
        responses: { '201': { description: 'Created' } },
      },
    },
    '/households/{householdId}/tasks/{taskId}/complete': {
      patch: {
        tags: ['Tasks'],
        summary: 'Mark a task complete (auto-generates next recurring occurrence)',
        security: bearerAuth,
        parameters: [
          { name: 'householdId', in: 'path', required: true, schema: { type: 'string' } },
          { name: 'taskId', in: 'path', required: true, schema: { type: 'string' } },
        ],
        responses: { '200': { description: 'Completed' } },
      },
    },
    '/households/{householdId}/tasks/{taskId}/restore': {
      post: {
        tags: ['Tasks'],
        summary: 'Restore a soft-deleted task (TD-009; creator or admin only)',
        security: bearerAuth,
        parameters: [
          { name: 'householdId', in: 'path', required: true, schema: { type: 'string' } },
          { name: 'taskId', in: 'path', required: true, schema: { type: 'string' } },
        ],
        responses: {
          '200': { description: 'Restored (or already-active — idempotent no-op)' },
          '403': { description: 'Not the task creator or a household admin' },
          '404': { description: 'Task not found' },
        },
      },
    },
    '/households/{householdId}/tasks/purge': {
      post: {
        tags: ['Tasks'],
        summary: 'Hard-delete soft-deleted tasks older than N days (TD-048; admin only)',
        security: bearerAuth,
        parameters: [
          { name: 'householdId', in: 'path', required: true, schema: { type: 'string' } },
          {
            name: 'days',
            in: 'query',
            required: false,
            description: 'Retention window in days; out of range responds 400',
            schema: { type: 'integer', minimum: 0, default: 30 },
          },
        ],
        responses: {
          '200': {
            description: 'Purge result',
            content: {
              'application/json': {
                schema: {
                  type: 'object',
                  properties: {
                    success: { type: 'boolean' },
                    data: {
                      type: 'object',
                      properties: { deleted: { type: 'integer' } },
                    },
                  },
                },
              },
            },
          },
          '400': {
            description: 'Invalid days',
            content: { 'application/json': { schema: { $ref: '#/components/schemas/Error' } } },
          },
          '403': { description: 'Caller is not a household admin' },
        },
      },
    },
    '/households/{householdId}/tasks/generate-instances': {
      post: {
        tags: ['Tasks'],
        summary: 'Catch-up: generate missed recurring occurrences',
        security: bearerAuth,
        parameters: [
          { name: 'householdId', in: 'path', required: true, schema: { type: 'string' } },
        ],
        requestBody: {
          required: false,
          content: {
            'application/json': {
              schema: {
                type: 'object',
                properties: { upTo: { type: 'string', format: 'date-time' } },
              },
            },
          },
        },
        responses: { '200': { description: 'Generated count + tasks' } },
      },
    },
    '/households/{householdId}/shopping': {
      get: {
        tags: ['Shopping'],
        summary: 'List shopping items (not purchased first)',
        security: bearerAuth,
        parameters: [
          { name: 'householdId', in: 'path', required: true, schema: { type: 'string' } },
          {
            name: 'limit',
            in: 'query',
            required: false,
            description: 'Page size; out of range responds 400',
            schema: { type: 'integer', minimum: 1, maximum: 100, default: 50 },
          },
          {
            name: 'cursor',
            in: 'query',
            required: false,
            description: 'Opaque cursor from a previous nextCursor; malformed responds 400',
            schema: { type: 'string' },
          },
        ],
        responses: {
          '200': {
            description: 'One page of shopping items',
            content: {
              'application/json': {
                schema: {
                  type: 'object',
                  properties: {
                    success: { type: 'boolean' },
                    data: {
                      allOf: [
                        { $ref: '#/components/schemas/Page' },
                        {
                          type: 'object',
                          properties: {
                            items: {
                              type: 'array',
                              items: { $ref: '#/components/schemas/ShoppingItem' },
                            },
                          },
                        },
                      ],
                    },
                  },
                },
              },
            },
          },
          '400': {
            description: 'Invalid limit or cursor',
            content: { 'application/json': { schema: { $ref: '#/components/schemas/Error' } } },
          },
        },
      },
      post: {
        tags: ['Shopping'],
        summary: 'Add a shopping item',
        security: bearerAuth,
        parameters: [
          { name: 'householdId', in: 'path', required: true, schema: { type: 'string' } },
          idempotencyKeyHeader,
        ],
        responses: { '201': { description: 'Created' } },
      },
    },
    '/households/{householdId}/pet': {
      get: {
        tags: ['Pet'],
        summary: "Get the household's pet, hunger/mood decayed to now",
        security: bearerAuth,
        parameters: [
          { name: 'householdId', in: 'path', required: true, schema: { type: 'string' } },
        ],
        responses: {
          '200': {
            description: 'OK',
            content: {
              'application/json': {
                schema: {
                  type: 'object',
                  properties: {
                    success: { type: 'boolean' },
                    data: { $ref: '#/components/schemas/Pet' },
                  },
                },
              },
            },
          },
          '404': { description: 'This household has not adopted a pet yet' },
        },
      },
    },
    '/households/{householdId}/pet/adopt': {
      get: {
        tags: ['Pet'],
        summary: 'Get the pending adoption request, if any',
        security: bearerAuth,
        parameters: [
          { name: 'householdId', in: 'path', required: true, schema: { type: 'string' } },
        ],
        responses: {
          '200': {
            description: 'OK',
            content: {
              'application/json': {
                schema: {
                  type: 'object',
                  properties: {
                    success: { type: 'boolean' },
                    data: { $ref: '#/components/schemas/AdoptionRequest' },
                  },
                },
              },
            },
          },
          '404': { description: 'No pending adoption request for this household' },
        },
      },
      post: {
        tags: ['Pet'],
        summary: 'Start a household adoption',
        description:
          '2+ member households get a pending AdoptionRequest requiring a DIFFERENT ' +
          'member to confirm (see POST .../adopt/confirm). A single-member household has ' +
          'nobody else who could ever confirm, so it adopts the Pet instantly instead — ' +
          'the response is the Pet itself, not a pending request.',
        security: bearerAuth,
        parameters: [
          { name: 'householdId', in: 'path', required: true, schema: { type: 'string' } },
          idempotencyKeyHeader,
        ],
        requestBody: {
          required: true,
          content: {
            'application/json': {
              schema: {
                type: 'object',
                required: ['species', 'name'],
                properties: {
                  species: { type: 'string', enum: ['cat', 'dog'] },
                  name: { type: 'string', minLength: 1, maxLength: 50 },
                },
              },
              example: { species: 'dog', name: 'Firulais' },
            },
          },
        },
        responses: {
          '201': {
            description:
              'A pending AdoptionRequest (2+ member household) OR the created Pet ' +
              '(single-member household, adopted instantly — see description above)',
            content: {
              'application/json': {
                schema: {
                  type: 'object',
                  properties: {
                    success: { type: 'boolean' },
                    data: {
                      oneOf: [
                        { $ref: '#/components/schemas/AdoptionRequest' },
                        { $ref: '#/components/schemas/Pet' },
                      ],
                    },
                  },
                },
              },
            },
          },
          '400': {
            description: 'The household already has a pet, or a request is already pending',
            content: { 'application/json': { schema: { $ref: '#/components/schemas/Error' } } },
          },
        },
      },
      delete: {
        tags: ['Pet'],
        summary: 'Cancel the pending adoption request (requester or household admin only)',
        security: bearerAuth,
        parameters: [
          { name: 'householdId', in: 'path', required: true, schema: { type: 'string' } },
        ],
        responses: {
          '200': { description: 'Cancelled' },
          '403': {
            description: 'Only the requester or a household admin can cancel this adoption',
            content: { 'application/json': { schema: { $ref: '#/components/schemas/Error' } } },
          },
          '404': { description: 'No pending adoption request for this household' },
        },
      },
    },
    '/households/{householdId}/pet/adopt/confirm': {
      post: {
        tags: ['Pet'],
        summary: 'Confirm a pending adoption',
        description:
          'Must be a DIFFERENT member than the one who requested it (cooperative ' +
          'consensus, PDR-001) — creates the Pet, deletes the request, and grants the ' +
          'one-time adoption bonus.',
        security: bearerAuth,
        parameters: [
          { name: 'householdId', in: 'path', required: true, schema: { type: 'string' } },
          idempotencyKeyHeader,
        ],
        responses: {
          '201': {
            description: 'Pet created',
            content: {
              'application/json': {
                schema: {
                  type: 'object',
                  properties: {
                    success: { type: 'boolean' },
                    data: { $ref: '#/components/schemas/Pet' },
                  },
                },
              },
            },
          },
          '403': {
            description:
              'A different household member must confirm the adoption (the requester ' +
              'tried to confirm their own request)',
            content: { 'application/json': { schema: { $ref: '#/components/schemas/Error' } } },
          },
          '404': { description: 'No pending adoption request for this household (or it expired)' },
        },
      },
    },
    '/households/{householdId}/pet/feed': {
      post: {
        tags: ['Pet'],
        summary: `Feed the pet: restores ${FEED_AMOUNT} hunger, gated by a ${FEED_COOLDOWN_HOURS}h cooldown`,
        security: bearerAuth,
        parameters: [
          { name: 'householdId', in: 'path', required: true, schema: { type: 'string' } },
        ],
        responses: {
          '200': {
            description: 'OK',
            content: {
              'application/json': {
                schema: {
                  type: 'object',
                  properties: {
                    success: { type: 'boolean' },
                    data: { $ref: '#/components/schemas/Pet' },
                  },
                },
              },
            },
          },
          '404': { description: 'This household has not adopted a pet yet' },
          '409': {
            description: 'The pet was already fed recently — try again later',
            content: { 'application/json': { schema: { $ref: '#/components/schemas/Error' } } },
          },
        },
      },
    },
    '/households/{householdId}/pet/play': {
      post: {
        tags: ['Pet'],
        summary: `Play with the pet: restores ${PLAY_AMOUNT} mood, gated by a ${PLAY_COOLDOWN_HOURS}h cooldown`,
        security: bearerAuth,
        parameters: [
          { name: 'householdId', in: 'path', required: true, schema: { type: 'string' } },
        ],
        responses: {
          '200': {
            description: 'OK',
            content: {
              'application/json': {
                schema: {
                  type: 'object',
                  properties: {
                    success: { type: 'boolean' },
                    data: { $ref: '#/components/schemas/Pet' },
                  },
                },
              },
            },
          },
          '404': { description: 'This household has not adopted a pet yet' },
          '409': {
            description: 'The pet already played recently — try again later',
            content: { 'application/json': { schema: { $ref: '#/components/schemas/Error' } } },
          },
        },
      },
    },
    '/households/{householdId}/pet/cosmetics/buy': {
      post: {
        tags: ['Pet'],
        summary: "Spend coins on a cosmetic and add it to the pet's cosmetics",
        security: bearerAuth,
        parameters: [
          { name: 'householdId', in: 'path', required: true, schema: { type: 'string' } },
          idempotencyKeyHeader,
        ],
        requestBody: {
          required: true,
          content: {
            'application/json': {
              schema: {
                type: 'object',
                required: ['cosmeticId'],
                properties: { cosmeticId: { type: 'string', enum: cosmeticIds } },
              },
              example: { cosmeticId: 'hat' },
            },
          },
        },
        responses: {
          '200': {
            description: 'Cosmetic purchased',
            content: {
              'application/json': {
                schema: {
                  type: 'object',
                  properties: {
                    success: { type: 'boolean' },
                    data: { $ref: '#/components/schemas/Pet' },
                  },
                },
              },
            },
          },
          '400': {
            description: 'Unknown cosmeticId, already owned, or insufficient balance',
            content: { 'application/json': { schema: { $ref: '#/components/schemas/Error' } } },
          },
          '404': { description: 'This household has not adopted a pet yet' },
          '409': {
            description:
              'Race: this cosmetic was already bought by a concurrent request for the ' +
              'same household (the ledger unique index is the real guard; the 400 above ' +
              'is the common-case fast path)',
            content: { 'application/json': { schema: { $ref: '#/components/schemas/Error' } } },
          },
        },
      },
    },
    '/households/{householdId}/pet/cosmetics/active': {
      post: {
        tags: ['Pet'],
        summary: "Set the pet's active cosmetic (must already be owned)",
        security: bearerAuth,
        parameters: [
          { name: 'householdId', in: 'path', required: true, schema: { type: 'string' } },
        ],
        requestBody: {
          required: true,
          content: {
            'application/json': {
              schema: {
                type: 'object',
                required: ['cosmeticId'],
                properties: { cosmeticId: { type: 'string', enum: cosmeticIds } },
              },
              example: { cosmeticId: 'hat' },
            },
          },
        },
        responses: {
          '200': {
            description: 'OK',
            content: {
              'application/json': {
                schema: {
                  type: 'object',
                  properties: {
                    success: { type: 'boolean' },
                    data: { $ref: '#/components/schemas/Pet' },
                  },
                },
              },
            },
          },
          '400': {
            description: 'This household does not own this cosmetic',
            content: { 'application/json': { schema: { $ref: '#/components/schemas/Error' } } },
          },
          '404': { description: 'This household has not adopted a pet yet' },
        },
      },
    },
    '/households/{householdId}/economy': {
      get: {
        tags: ['Economy'],
        summary: "Household's coin balance, today's earnings, and recent ledger entries",
        security: bearerAuth,
        parameters: [
          { name: 'householdId', in: 'path', required: true, schema: { type: 'string' } },
        ],
        responses: {
          '200': {
            description: 'OK',
            content: {
              'application/json': {
                schema: {
                  type: 'object',
                  properties: {
                    success: { type: 'boolean' },
                    data: {
                      type: 'object',
                      properties: {
                        balance: { type: 'integer', description: 'All-time balance' },
                        dailyEarned: {
                          type: 'integer',
                          description: 'Coins earned since the start of the current UTC day',
                        },
                        recentTransactions: {
                          type: 'array',
                          items: { $ref: '#/components/schemas/EconomyTransaction' },
                          description: 'Most recent ledger entries, newest first (limit 10)',
                        },
                      },
                    },
                  },
                },
              },
            },
          },
        },
      },
    },
  },
};
