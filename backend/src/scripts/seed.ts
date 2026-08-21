import 'dotenv/config';
import bcrypt from 'bcryptjs';
import { Types } from 'mongoose';
import { connectDatabase, disconnectDatabase } from '../config/database';
import { UserModel } from '../models/User';
import { HouseholdModel } from '../models/Household';
import { HouseholdMemberModel } from '../models/HouseholdMember';
import { TaskModel } from '../models/Task';
import { ShoppingItemModel } from '../models/ShoppingItem';
import { logger } from '../utils/logger';

const TEST_EMAIL = 'test@test.com';
const TEST_PASSWORD = 'password123';
const INVITE_CODE = 'CASADEMO';

/** Days from now as a Date (with a fixed time-of-day). */
function inDays(days: number, hour = 9): Date {
  const d = new Date();
  d.setDate(d.getDate() + days);
  d.setHours(hour, 0, 0, 0);
  return d;
}

/**
 * Idempotent seed: wipes any prior data for the test user, then recreates a
 * user, household, 5 tasks (2 recurring + 3 one-off) and 3 shopping items.
 *
 * Run with: npx ts-node src/scripts/seed.ts
 */
async function seed(): Promise<void> {
  await connectDatabase();
  logger.info('Seeding database...');

  // ---- Clean previous test data (idempotency) ----
  const existing = await UserModel.findOne({ email: TEST_EMAIL });
  if (existing) {
    // TD-001 phase 4: membership lives in HouseholdMember, so the households
    // to clean up are found there. Querying `members.user` would silently miss
    // everything seeded after the dual write was retired and leak households
    // on every re-seed.
    const memberships = await HouseholdMemberModel.find({ userId: existing._id }).select(
      'householdId',
    );
    const householdIds = memberships.map((m) => m.householdId);
    await TaskModel.deleteMany({ householdId: { $in: householdIds } });
    await ShoppingItemModel.deleteMany({ householdId: { $in: householdIds } });
    await HouseholdModel.deleteMany({ _id: { $in: householdIds } });
    await HouseholdMemberModel.deleteMany({ householdId: { $in: householdIds } });
    await UserModel.deleteOne({ _id: existing._id });
    logger.info('Removed existing test data');
  }

  // ---- User ----
  const passwordHash = await bcrypt.hash(TEST_PASSWORD, 10);
  const user = await UserModel.create({
    email: TEST_EMAIL,
    password: passwordHash,
    name: 'Usuario de prueba',
  });

  // ---- Household ----
  const household = await HouseholdModel.create({
    name: 'Casa de prueba',
    inviteCode: INVITE_CODE,
    createdBy: user._id,
  });
  // The membership row IS the membership since TD-001 phase 4. Without it the
  // seeded household is unreachable: requireMembership reads this collection,
  // so every request against it would answer 403.
  await HouseholdMemberModel.create({
    householdId: household._id,
    userId: user._id,
    role: 'admin',
    joinedAt: new Date(),
  });
  await UserModel.updateOne({ _id: user._id }, { $addToSet: { households: household._id } });

  const householdId = household._id as Types.ObjectId;

  // ---- Tasks: 2 recurring + 3 one-off ----
  await TaskModel.create([
    {
      householdId,
      title: 'Sacar la basura',
      description: 'Contenedor amarillo y orgánico',
      assignedTo: [user._id],
      createdBy: user._id,
      priority: 'medium',
      category: 'cleaning',
      status: 'pending',
      dueDate: inDays(0, 20),
      isRecurring: true,
      recurrenceRule: { type: 'daily', interval: 1 },
    },
    {
      householdId,
      title: 'Limpiar el baño',
      assignedTo: [user._id],
      createdBy: user._id,
      priority: 'high',
      category: 'cleaning',
      status: 'pending',
      dueDate: inDays(2, 11),
      isRecurring: true,
      recurrenceRule: { type: 'weekly', interval: 1, daysOfWeek: [6] },
    },
    {
      householdId,
      title: 'Comprar regalo de cumpleaños',
      assignedTo: [user._id],
      createdBy: user._id,
      priority: 'high',
      category: 'shopping',
      status: 'pending',
      dueDate: inDays(5),
      isRecurring: false,
    },
    {
      householdId,
      title: 'Revisar la caldera',
      assignedTo: [user._id],
      createdBy: user._id,
      priority: 'low',
      category: 'maintenance',
      status: 'pending',
      dueDate: inDays(10),
      isRecurring: false,
    },
    {
      householdId,
      title: 'Preparar la cena del viernes',
      assignedTo: [user._id],
      createdBy: user._id,
      priority: 'medium',
      category: 'cooking',
      status: 'pending',
      dueDate: inDays(3, 19),
      isRecurring: false,
    },
  ]);

  // ---- Shopping items ----
  await ShoppingItemModel.create([
    {
      householdId,
      name: 'Leche',
      quantity: 2,
      unit: 'litros',
      category: 'fridge',
      addedBy: user._id,
      isRecurring: true,
      recurrenceIntervalDays: 7,
    },
    {
      householdId,
      name: 'Papel higiénico',
      quantity: 1,
      unit: 'paquetes',
      category: 'personal',
      addedBy: user._id,
    },
    {
      householdId,
      name: 'Detergente',
      quantity: 1,
      unit: 'uds',
      category: 'cleaning',
      addedBy: user._id,
      estimatedPrice: 8.5,
    },
  ]);

  logger.info('Seed complete:');
  logger.info(`  Login:        ${TEST_EMAIL} / ${TEST_PASSWORD}`);
  logger.info(`  Household:    "${household.name}" (invite code: ${INVITE_CODE})`);
  logger.info('  Tasks:        5 (2 recurring, 3 one-off)');
  logger.info('  Shopping:     3 items');
}

seed()
  .then(async () => {
    await disconnectDatabase();
    process.exit(0);
  })
  .catch(async (err) => {
    logger.error('Seed failed', (err as Error).message);
    await disconnectDatabase().catch(() => undefined);
    process.exit(1);
  });
