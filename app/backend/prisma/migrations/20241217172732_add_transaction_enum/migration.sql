-- Step 1: Create a new temporary column for the enum
ALTER TABLE "Transaction" ADD COLUMN "new_type" TEXT;

-- Step 2: Update the temporary column with valid enum values
UPDATE "Transaction"
SET "new_type" = CASE
  WHEN "type" = 'DEPOSIT' THEN 'DEPOSIT'
  WHEN "type" = 'WITHDRAW' THEN 'WITHDRAW'
  WHEN "type" = 'TRANSFER' THEN 'TRANSFER'
  ELSE NULL
END;

-- Step 3: Ensure no invalid data exists in the original column
-- (Optional: Validate before proceeding)
SELECT * FROM "Transaction" WHERE "new_type" IS NULL;

-- Step 4: Drop the original column and rename the temporary column
ALTER TABLE "Transaction" DROP COLUMN "type";
ALTER TABLE "Transaction" RENAME COLUMN "new_type" TO "type";

-- Step 5: Add the enum constraint to the new column
CREATE TYPE "TransactionType" AS ENUM ('DEPOSIT', 'WITHDRAW', 'TRANSFER');
ALTER TABLE "Transaction" ALTER COLUMN "type" SET DATA TYPE "TransactionType" USING ("type"::"TransactionType");
