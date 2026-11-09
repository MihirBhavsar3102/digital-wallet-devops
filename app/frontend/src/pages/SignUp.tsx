import React from "react";
import { useFormik } from "formik";
import * as Yup from "yup";
import { useAuth } from "../context/AuthContext";
import { useNavigate } from "react-router-dom";
import { toast } from "react-toastify";
import api from "../services/axios";

const SignUp: React.FC = () => {
  const { login } = useAuth();
  const navigate = useNavigate();

  const formik = useFormik({
    initialValues: {
      username: "",
      email: "",
      password: "",
    },
    validationSchema: Yup.object({
      username: Yup.string()
        .min(3, "Username must be at least 3 characters")
        .required("Username is required"),
      email: Yup.string()
        .email("Invalid email address")
        .required("Email is required"),
      password: Yup.string()
        .min(6, "Password must be at least 6 characters")
        .required("Password is required"),
    }),
    onSubmit: async (values, { setSubmitting }) => {
      try {
        // Call the registration endpoint
        const response = await api.post("/users/register", values);

        if (response.status === 201) {
          toast.success("Registration successful! Logging in...");
          await login(values.username, values.password);
          navigate("/dashboard");
        } else {
          throw new Error("Unexpected response status");
        }
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
      } catch (error: any) {
        toast.error(error.response?.data?.message || "Failed to register.");
      } finally {
        setSubmitting(false);
      }
    },
  });

  return (
    <div className="flex items-center justify-center min-h-screen bg-gradient-to-br from-gray-50 via-gray-100 to-gray-200">
      <div className="p-10 bg-white rounded-xl shadow-xl w-full max-w-md">
        <div className="mb-8 text-center">
          <h1 className="text-2xl font-semibold text-gray-800 mb-2">
            Create Your Digital Wallet Account
          </h1>
          <p className="text-gray-600 text-sm">
            Sign up to access your secure digital wallet.
          </p>
        </div>

        <form onSubmit={formik.handleSubmit} className="space-y-5">
          <div>
            <label
              htmlFor="username"
              className="block text-gray-700 font-medium text-sm mb-2"
            >
              Username
            </label>
            <input
              id="username"
              type="text"
              placeholder="Choose a username"
              value={formik.values.username}
              onChange={formik.handleChange}
              onBlur={formik.handleBlur}
              className={`w-full p-3 border rounded-lg shadow-sm focus:outline-none focus:ring-2 ${
                formik.touched.username && formik.errors.username
                  ? "border-red-500"
                  : "focus:ring-gray-300"
              }`}
            />
            {formik.touched.username && formik.errors.username && (
              <p className="text-red-500 text-sm mt-1">
                {formik.errors.username}
              </p>
            )}
          </div>
          <div>
            <label
              htmlFor="email"
              className="block text-gray-700 font-medium text-sm mb-2"
            >
              Email
            </label>
            <input
              id="email"
              type="email"
              placeholder="Enter your email"
              value={formik.values.email}
              onChange={formik.handleChange}
              onBlur={formik.handleBlur}
              className={`w-full p-3 border rounded-lg shadow-sm focus:outline-none focus:ring-2 ${
                formik.touched.email && formik.errors.email
                  ? "border-red-500"
                  : "focus:ring-gray-300"
              }`}
            />
            {formik.touched.email && formik.errors.email && (
              <p className="text-red-500 text-sm mt-1">{formik.errors.email}</p>
            )}
          </div>
          <div>
            <label
              htmlFor="password"
              className="block text-gray-700 font-medium text-sm mb-2"
            >
              Password
            </label>
            <input
              id="password"
              type="password"
              placeholder="Create a password"
              value={formik.values.password}
              onChange={formik.handleChange}
              onBlur={formik.handleBlur}
              className={`w-full p-3 border rounded-lg shadow-sm focus:outline-none focus:ring-2 ${
                formik.touched.password && formik.errors.password
                  ? "border-red-500"
                  : "focus:ring-gray-300"
              }`}
            />
            {formik.touched.password && formik.errors.password && (
              <p className="text-red-500 text-sm mt-1">
                {formik.errors.password}
              </p>
            )}
          </div>
          <button
            type="submit"
            disabled={formik.isSubmitting}
            className="w-full py-3 bg-blue-500 text-white font-medium rounded-lg shadow-md hover:bg-blue-600 transition disabled:opacity-50"
          >
            {formik.isSubmitting ? "Registering..." : "Sign Up"}
          </button>
        </form>

        <div className="mt-8 text-center">
          <p className="text-gray-600">
            Already have an account?{" "}
            <span
              onClick={() => navigate("/")}
              className="text-blue-500 hover:underline cursor-pointer"
            >
              Log in here
            </span>
          </p>
        </div>
      </div>
    </div>
  );
};

export default SignUp;
