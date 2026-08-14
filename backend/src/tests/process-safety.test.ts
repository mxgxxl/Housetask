import { logger } from '../utils/logger';
// Importing server.ts registers the process-level handler at module load. It
// does NOT boot the server: start() only runs when the module is the entry
// point (require.main === module), which is never true under Jest.
import { handleUnhandledRejection } from '../server';

describe('unhandledRejection safety net (TD-032)', () => {
  it('should register exactly one handler', () => {
    expect(process.listeners('unhandledRejection')).toContain(handleUnhandledRejection);
    expect(
      process.listeners('unhandledRejection').filter((l) => l === handleUnhandledRejection),
    ).toHaveLength(1);
  });

  it('should log the stack and never exit when invoked with a rejection', () => {
    const error = jest.spyOn(logger, 'error').mockImplementation(() => undefined);
    const exit = jest.spyOn(process, 'exit').mockImplementation((() => undefined) as never);

    // Invoked directly rather than by letting a promise float: Jest installs
    // its own unhandledRejection listener and fails the test before ours runs,
    // so the real end-to-end path is exercised against a running server
    // instead (see the manual verification).
    handleUnhandledRejection(new Error('simulated'));

    const calls = [...error.mock.calls];
    error.mockRestore();
    exit.mockRestore();

    const logged = calls.find(([message]) => message === 'unhandledRejection');
    expect(logged).toBeDefined();
    // The stack, not just the message: an adapter rejection is useless without
    // knowing which library queued it.
    expect(JSON.stringify(logged?.[1])).toContain('simulated');
    expect(JSON.stringify(logged?.[1])).toContain('process-safety.test');
    // The whole point: observe, never exit. Terminating here would turn a
    // Redis blip inside the Socket.io adapter into a crash loop.
    expect(exit).not.toHaveBeenCalled();
  });

  it('should handle a non-Error rejection value without throwing', () => {
    const error = jest.spyOn(logger, 'error').mockImplementation(() => undefined);

    try {
      expect(() => handleUnhandledRejection('simulated string')).not.toThrow();
      expect(error).toHaveBeenCalledWith('unhandledRejection', {
        error: 'simulated string',
      });
    } finally {
      error.mockRestore();
    }
  });
});
