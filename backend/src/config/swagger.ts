/**
 * Basic OpenAPI 3.0 specification for the HomeSync API, served via
 * swagger-ui-express at /api/docs.
 */

const bearerAuth = [{ bearerAuth: [] }];

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
        parameters: [
          { name: 'id', in: 'path', required: true, schema: { type: 'string' } },
        ],
        responses: { '200': { description: 'OK' }, '403': { description: 'Forbidden' } },
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
            schema: { type: 'string', enum: ['pending', 'completed'] },
          },
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
                    data: { type: 'array', items: { $ref: '#/components/schemas/Task' } },
                  },
                },
              },
            },
          },
        },
      },
      post: {
        tags: ['Tasks'],
        summary: 'Create a task',
        security: bearerAuth,
        parameters: [
          { name: 'householdId', in: 'path', required: true, schema: { type: 'string' } },
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
        ],
        responses: { '200': { description: 'OK' } },
      },
      post: {
        tags: ['Shopping'],
        summary: 'Add a shopping item',
        security: bearerAuth,
        parameters: [
          { name: 'householdId', in: 'path', required: true, schema: { type: 'string' } },
        ],
        responses: { '201': { description: 'Created' } },
      },
    },
  },
};
