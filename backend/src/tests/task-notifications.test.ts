import { Server } from 'http';
import request from 'supertest';

import { buildTestApp } from './setup';
import * as notificationService from '../services/notification.service';
import { logger } from '../utils/logger';
import { authHeader, createHouseholdWithMember } from './helpers';

let app: Server;

beforeAll(async () => {
  app = await buildTestApp();
});

/**
 * Push notification triggers (PDR-008): task.service.ts's createTask calls
 * notifyTaskAssigned, completeTask calls notifyTaskCompleted. Both are
 * fire-and-forget wrappers around notification.service.sendPushNotification
 * — spying on the exported function (same pattern sentry.test.ts uses for
 * captureServerError) verifies the trigger fires with the right arguments
 * without needing a real Firebase Admin setup.
 */
describe('Push notification triggers (PDR-008)', () => {
  let sendPushSpy: jest.SpyInstance;

  beforeEach(() => {
    sendPushSpy = jest
      .spyOn(notificationService, 'sendPushNotification')
      .mockResolvedValue({ sent: 1, failed: 0 });
  });

  afterEach(() => {
    sendPushSpy.mockRestore();
  });

  describe('createTask', () => {
    it('should push each assignee other than the creator', async () => {
      const { admin, member, household } = await createHouseholdWithMember(app);

      const res = await request(app)
        .post(`/api/households/${household.id}/tasks`)
        .set(authHeader(admin.accessToken))
        .send({ title: 'Fregar los platos', assignedTo: [member.id] });

      expect(res.status).toBe(201);
      expect(sendPushSpy).toHaveBeenCalledTimes(1);
      expect(sendPushSpy).toHaveBeenCalledWith(
        member.id,
        'Nueva tarea asignada',
        `${admin.name} te asignó: Fregar los platos`,
        { type: 'task', taskId: res.body.data.id },
      );
    });

    it('should not push anyone when the creator assigns the task only to themselves', async () => {
      const { admin, household } = await createHouseholdWithMember(app);

      const res = await request(app)
        .post(`/api/households/${household.id}/tasks`)
        .set(authHeader(admin.accessToken))
        .send({ title: 'Solo yo', assignedTo: [admin.id] });

      expect(res.status).toBe(201);
      expect(sendPushSpy).not.toHaveBeenCalled();
    });

    it('should not push anyone when the task has no assignees', async () => {
      const { admin, household } = await createHouseholdWithMember(app);

      const res = await request(app)
        .post(`/api/households/${household.id}/tasks`)
        .set(authHeader(admin.accessToken))
        .send({ title: 'Sin asignar' });

      expect(res.status).toBe(201);
      expect(sendPushSpy).not.toHaveBeenCalled();
    });

    it('should still create the task when sending the push notification fails', async () => {
      const errorLog = jest.spyOn(logger, 'error').mockImplementation(() => undefined);
      sendPushSpy.mockRejectedValue(new Error('FCM unavailable'));
      const { admin, member, household } = await createHouseholdWithMember(app);

      const res = await request(app)
        .post(`/api/households/${household.id}/tasks`)
        .set(authHeader(admin.accessToken))
        .send({ title: 'Con fallo de push', assignedTo: [member.id] });

      expect(res.status).toBe(201);
      errorLog.mockRestore();
    });
  });

  describe('completeTask', () => {
    async function createTask(
      creator: { accessToken: string },
      householdId: string,
      title: string,
    ): Promise<string> {
      const res = await request(app)
        .post(`/api/households/${householdId}/tasks`)
        .set(authHeader(creator.accessToken))
        .send({ title });
      return res.body.data.id as string;
    }

    it('should push the creator when someone else completes their task', async () => {
      const { admin, member, household } = await createHouseholdWithMember(app);
      const taskId = await createTask(admin, household.id, 'Sacar la basura');
      sendPushSpy.mockClear(); // creation with no assignees never calls it, but keep intent explicit

      const res = await request(app)
        .patch(`/api/households/${household.id}/tasks/${taskId}/complete`)
        .set(authHeader(member.accessToken));

      expect(res.status).toBe(200);
      expect(sendPushSpy).toHaveBeenCalledTimes(1);
      expect(sendPushSpy).toHaveBeenCalledWith(
        admin.id,
        'Tarea completada',
        `${member.name} completó: Sacar la basura`,
        { type: 'task', taskId },
      );
    });

    it('should not push when the creator completes their own task', async () => {
      const { admin, household } = await createHouseholdWithMember(app);
      const taskId = await createTask(admin, household.id, 'Propia');
      sendPushSpy.mockClear();

      const res = await request(app)
        .patch(`/api/households/${household.id}/tasks/${taskId}/complete`)
        .set(authHeader(admin.accessToken));

      expect(res.status).toBe(200);
      expect(sendPushSpy).not.toHaveBeenCalled();
    });

    it('should still complete the task when sending the push notification fails', async () => {
      const { admin, member, household } = await createHouseholdWithMember(app);
      const taskId = await createTask(admin, household.id, 'Con fallo');
      sendPushSpy.mockClear();
      const errorLog = jest.spyOn(logger, 'error').mockImplementation(() => undefined);
      sendPushSpy.mockRejectedValue(new Error('FCM unavailable'));

      const res = await request(app)
        .patch(`/api/households/${household.id}/tasks/${taskId}/complete`)
        .set(authHeader(member.accessToken));

      expect(res.status).toBe(200);
      errorLog.mockRestore();
    });
  });
});
