/** Serializes complete clipboard transfers, including explicitly requested uploads. */
export class SyncOperationQueue {
  private static tail: Promise<void> = Promise.resolve();

  static run<T>(operation: () => Promise<T>): Promise<T> {
    const result = SyncOperationQueue.tail.then(operation);
    SyncOperationQueue.tail = result.then((): void => {}, (): void => {});
    return result;
  }
}
