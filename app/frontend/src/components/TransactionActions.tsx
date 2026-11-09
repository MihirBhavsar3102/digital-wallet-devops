/* eslint-disable react-hooks/rules-of-hooks */
import React from "react";
import { useFormik } from "formik";
import * as Yup from "yup";
import { useAuth } from "../context/AuthContext";

const TransactionActions: React.FC = () => {
  const { currentAccount, deposit, withdraw, transfer, allAccounts } =
    useAuth();

  if (!currentAccount) {
    return <p className="text-center text-gray-600">No account selected.</p>;
  }

  const depositFormik = useFormik({
    initialValues: { amount: "" },
    validationSchema: Yup.object({
      amount: Yup.number()
        .min(1, "Deposit amount must be at least 1")
        .required("Deposit amount is required"),
    }),
    onSubmit: (values, { resetForm }) => {
      deposit(Number(values.amount));
      resetForm();
    },
  });

  const withdrawFormik = useFormik({
    initialValues: { amount: "" },
    validationSchema: Yup.object({
      amount: Yup.number()
        .min(1, "Withdrawal amount must be at least 1")
        .required("Withdrawal amount is required"),
    }),
    onSubmit: (values, { resetForm }) => {
      withdraw(Number(values.amount));
      resetForm();
    },
  });

  const transferFormik = useFormik({
    initialValues: { recipient: "", amount: "" },
    validationSchema: Yup.object({
      recipient: Yup.string().required("Recipient is required"),
      amount: Yup.number()
        .min(1, "Transfer amount must be at least 1")
        .required("Transfer amount is required"),
    }),
    onSubmit: (values, { resetForm }) => {
      transfer(
        Number(values.recipient),
        Number(values.amount),
        Number(currentAccount.id)
      );
      resetForm();
    },
  });

  return (
    <div className="grid grid-cols-1 lg:grid-cols-4 gap-6 py-6">
      {/* Deposit */}
      <div className="p-6 bg-gray-100 rounded-lg shadow-md">
        <h2 className="text-lg font-semibold mb-4 text-gray-700">Deposit</h2>
        <form onSubmit={depositFormik.handleSubmit} className="space-y-4">
          <div className="flex flex-col">
            <input
              type="number"
              name="amount"
              placeholder="Enter deposit amount"
              value={depositFormik.values.amount}
              onChange={depositFormik.handleChange}
              onBlur={depositFormik.handleBlur}
              className={`w-full p-3 border rounded-lg focus:outline-none focus:ring-2 ${
                depositFormik.touched.amount && depositFormik.errors.amount
                  ? "border-red-500"
                  : "focus:ring-blue-400"
              }`}
            />
            <div className="h-5">
              {depositFormik.touched.amount && depositFormik.errors.amount && (
                <p className="text-red-500 text-sm">
                  {depositFormik.errors.amount}
                </p>
              )}
            </div>
          </div>
          <button
            type="submit"
            className="w-full p-3 bg-blue-500 text-white font-medium rounded-lg hover:bg-blue-600 transition"
          >
            Deposit
          </button>
        </form>
      </div>

      {/* Withdraw */}
      <div className="p-6 bg-gray-100 rounded-lg shadow-md">
        <h2 className="text-lg font-semibold mb-4 text-gray-700">Withdraw</h2>
        <form onSubmit={withdrawFormik.handleSubmit} className="space-y-4">
          <div className="flex flex-col">
            <input
              type="number"
              name="amount"
              placeholder="Enter withdrawal amount"
              value={withdrawFormik.values.amount}
              onChange={withdrawFormik.handleChange}
              onBlur={withdrawFormik.handleBlur}
              className={`w-full p-3 border rounded-lg focus:outline-none focus:ring-2 ${
                withdrawFormik.touched.amount && withdrawFormik.errors.amount
                  ? "border-red-500"
                  : "focus:ring-blue-400"
              }`}
            />
            <div className="h-5">
              {withdrawFormik.touched.amount &&
                withdrawFormik.errors.amount && (
                  <p className="text-red-500 text-sm">
                    {withdrawFormik.errors.amount}
                  </p>
                )}
            </div>
          </div>
          <button
            type="submit"
            className="w-full p-3 bg-blue-500 text-white font-medium rounded-lg hover:bg-blue-600 transition"
          >
            Withdraw
          </button>
        </form>
      </div>

      {/* Transfer */}
      <div className="p-6 bg-gray-100 rounded-lg shadow-md lg:col-span-2">
        <h2 className="text-lg font-semibold mb-4 text-gray-700">Transfer</h2>
        <form onSubmit={transferFormik.handleSubmit} className="space-y-4">
          <div className="flex flex-col lg:flex-row gap-4">
            <div className="flex flex-col">
              <select
                name="recipient"
                value={transferFormik.values.recipient}
                onChange={transferFormik.handleChange}
                onBlur={transferFormik.handleBlur}
                className={`w-full p-3 border rounded-lg focus:outline-none focus:ring-2 ${
                  transferFormik.touched.recipient &&
                  transferFormik.errors.recipient
                    ? "border-red-500"
                    : "focus:ring-blue-400"
                }`}
              >
                <option value="" disabled>
                  Select Recipient
                </option>
                {allAccounts
                  .filter((account) => account.id !== Number(currentAccount.id))
                  .map((account) => (
                    <option key={account.id} value={account.id}>
                      {account.user.username} - Account #{account.id}
                    </option>
                  ))}
              </select>
              <div className="h-5">
                {transferFormik.touched.recipient &&
                  transferFormik.errors.recipient && (
                    <p className="text-red-500 text-sm">
                      {transferFormik.errors.recipient}
                    </p>
                  )}
              </div>
            </div>
            <div className="flex flex-col">
              <input
                type="number"
                name="amount"
                placeholder="Amount"
                value={transferFormik.values.amount}
                onChange={transferFormik.handleChange}
                onBlur={transferFormik.handleBlur}
                className={`w-full p-2 border rounded-lg focus:outline-none focus:ring-2 ${
                  transferFormik.touched.amount && transferFormik.errors.amount
                    ? "border-red-500"
                    : "focus:ring-blue-400"
                }`}
              />
              <div className="h-5">
                {transferFormik.touched.amount &&
                  transferFormik.errors.amount && (
                    <p className="text-red-500 text-sm">
                      {transferFormik.errors.amount}
                    </p>
                  )}
              </div>
            </div>
          </div>
          <button
            type="submit"
            className="w-full p-3 bg-blue-500 text-white font-medium rounded-lg hover:bg-blue-600 transition"
          >
            Transfer
          </button>
        </form>
      </div>
    </div>
  );
};

export default TransactionActions;
