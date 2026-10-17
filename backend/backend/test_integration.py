"""
Phase 1 Backend Integration Test Suite

Tests all authentication flows against the running FastAPI backend:
- Student registration
- Login with token generation and expiration
- Protected endpoint access with valid token
- Invalid/expired token rejection
- Logout functionality
- Data persistence verification
"""

import requests
import json
from datetime import datetime, timedelta
import time

BASE_URL = "http://localhost:8000"

class Colors:
    GREEN = '\033[92m'
    RED = '\033[91m'
    YELLOW = '\033[93m'
    BLUE = '\033[94m'
    RESET = '\033[0m'

def print_test(name):
    print(f"\n{Colors.BLUE}{'='*60}{Colors.RESET}")
    print(f"{Colors.BLUE}TEST: {name}{Colors.RESET}")
    print(f"{Colors.BLUE}{'='*60}{Colors.RESET}")

def print_success(message):
    print(f"{Colors.GREEN}✓ {message}{Colors.RESET}")

def print_error(message):
    print(f"{Colors.RED}✗ {message}{Colors.RESET}")

def print_info(message):
    print(f"{Colors.YELLOW}ℹ {message}{Colors.RESET}")

def test_1_register_student():
    """Test 1: Register a new test student"""
    print_test("Register New Student")

    student_data = {
        "name": "Test Student",
        "email": f"test_{int(time.time())}@example.com",
        "roll_number": f"TEST{int(time.time())}",
        "branch": "Computer Science",
        "year": 2,
        "division": "A",
        "batch": "B1",
        "password": "testpassword123"
    }

    print_info(f"Registering student: {student_data['email']}")

    response = requests.post(f"{BASE_URL}/register", json=student_data)

    if response.status_code == 201:
        data = response.json()
        print_success(f"Student registered successfully (ID: {data['student_id']})")
        return student_data, data['student_id']
    else:
        print_error(f"Registration failed: {response.status_code}")
        print_error(f"Response: {response.text}")
        raise Exception("Registration failed")

def test_2_login_student(student_data):
    """Test 2: Log in with the registered student"""
    print_test("Login Student")

    login_data = {
        "email": student_data["email"],
        "password": student_data["password"]
    }

    print_info(f"Logging in as: {login_data['email']}")

    response = requests.post(f"{BASE_URL}/login", json=login_data)

    if response.status_code == 200:
        data = response.json()
        print_success("Login successful")
        print_info(f"Student ID: {data['student_id']}")
        print_info(f"Token: {data['token'][:20]}...")
        return data
    else:
        print_error(f"Login failed: {response.status_code}")
        print_error(f"Response: {response.text}")
        raise Exception("Login failed")

def test_3_verify_token_expiration(login_response):
    """Test 3: Verify the returned token has an expiration"""
    print_test("Verify Token Expiration")

    if 'token_expires_at' in login_response:
        expiration = login_response['token_expires_at']
        print_success(f"Token has expiration: {expiration}")

        # Parse and verify expiration is in the future
        expiration_dt = datetime.fromisoformat(expiration.replace('Z', '+00:00'))
        now = datetime.utcnow()

        if expiration_dt > now:
            days_valid = (expiration_dt - now).days
            print_success(f"Token expires in {days_valid} days (valid)")
            return True
        else:
            print_error("Token expiration is in the past!")
            return False
    else:
        print_error("No token_expires_at field in login response")
        return False

def test_4_protected_endpoint(token):
    """Test 4: Use the token on a protected endpoint"""
    print_test("Access Protected Endpoint with Valid Token")

    headers = {"Authorization": f"Bearer {token}"}

    print_info("Accessing /me endpoint")
    response = requests.get(f"{BASE_URL}/me", headers=headers)

    if response.status_code == 200:
        data = response.json()
        print_success("Successfully accessed protected endpoint")
        print_info(f"Student: {data['name']} ({data['email']})")
        print_info(f"Year: {data['year']}, Division: {data['division']}, Batch: {data['batch']}")
        return data
    else:
        print_error(f"Failed to access protected endpoint: {response.status_code}")
        print_error(f"Response: {response.text}")
        raise Exception("Protected endpoint access failed")

def test_5_invalid_token():
    """Test 5: Verify an invalid token is rejected"""
    print_test("Verify Invalid Token Rejection")

    invalid_tokens = [
        ("No token", {}),
        ("Invalid format", {"Authorization": "InvalidFormat"}),
        ("Fake token", {"Authorization": "Bearer fake_token_12345"})
    ]

    all_passed = True
    for test_name, headers in invalid_tokens:
        print_info(f"Testing: {test_name}")
        response = requests.get(f"{BASE_URL}/me", headers=headers)

        if response.status_code == 401:
            print_success(f"  ✓ Correctly rejected with 401")
        else:
            print_error(f"  ✗ Expected 401, got {response.status_code}")
            all_passed = False

    return all_passed

def test_6_logout(token):
    """Test 6: Log out the student"""
    print_test("Logout Student")

    headers = {"Authorization": f"Bearer {token}"}

    print_info("Calling /logout endpoint")
    response = requests.post(f"{BASE_URL}/logout", headers=headers)

    if response.status_code == 200:
        data = response.json()
        print_success(f"Logout successful: {data['message']}")
        return True
    else:
        print_error(f"Logout failed: {response.status_code}")
        print_error(f"Response: {response.text}")
        return False

def test_7_verify_logout_behavior(token):
    """Test 7: Verify the logout behavior works as intended"""
    print_test("Verify Token Invalid After Logout")

    headers = {"Authorization": f"Bearer {token}"}

    print_info("Attempting to access /me with logged-out token")
    response = requests.get(f"{BASE_URL}/me", headers=headers)

    if response.status_code == 401:
        print_success("Token correctly invalidated after logout")
        return True
    else:
        print_error(f"Token still works after logout! Status: {response.status_code}")
        return False

def test_8_existing_records(student_data):
    """Test 8: Confirm existing student records are still accessible"""
    print_test("Verify Data Persistence")

    # Login again to get a fresh token
    login_data = {
        "email": student_data["email"],
        "password": student_data["password"]
    }

    print_info("Logging in again with same credentials")
    response = requests.post(f"{BASE_URL}/login", json=login_data)

    if response.status_code == 200:
        data = response.json()
        new_token = data['token']
        print_success("Successfully logged in again")
        print_info(f"New token: {new_token[:20]}...")

        # Verify we can access the account
        headers = {"Authorization": f"Bearer {new_token}"}
        me_response = requests.get(f"{BASE_URL}/me", headers=headers)

        if me_response.status_code == 200:
            me_data = me_response.json()
            print_success("Student record still accessible")
            print_info(f"Verified: {me_data['name']} ({me_data['email']})")
            return True
        else:
            print_error("Could not access student record")
            return False
    else:
        print_error("Could not log in again")
        return False

def run_all_tests():
    """Run all Phase 1 integration tests"""
    print(f"\n{Colors.BLUE}{'='*60}{Colors.RESET}")
    print(f"{Colors.BLUE}PHASE 1 BACKEND INTEGRATION TESTS{Colors.RESET}")
    print(f"{Colors.BLUE}{'='*60}{Colors.RESET}")
    print_info(f"Testing against: {BASE_URL}")

    results = []

    try:
        # Test 1: Register
        student_data, student_id = test_1_register_student()
        results.append(("Register Student", True))

        # Test 2: Login
        login_response = test_2_login_student(student_data)
        token = login_response['token']
        results.append(("Login Student", True))

        # Test 3: Verify token expiration
        expiration_valid = test_3_verify_token_expiration(login_response)
        results.append(("Token Expiration", expiration_valid))

        # Test 4: Protected endpoint access
        test_4_protected_endpoint(token)
        results.append(("Protected Endpoint Access", True))

        # Test 5: Invalid token rejection
        invalid_rejected = test_5_invalid_token()
        results.append(("Invalid Token Rejection", invalid_rejected))

        # Test 6: Logout
        logout_success = test_6_logout(token)
        results.append(("Logout", logout_success))

        # Test 7: Verify logout behavior
        logout_verified = test_7_verify_logout_behavior(token)
        results.append(("Logout Verification", logout_verified))

        # Test 8: Data persistence
        persistence_verified = test_8_existing_records(student_data)
        results.append(("Data Persistence", persistence_verified))

    except Exception as e:
        print_error(f"\nTest suite aborted: {str(e)}")
        results.append(("Aborted", False))

    # Print summary
    print(f"\n{Colors.BLUE}{'='*60}{Colors.RESET}")
    print(f"{Colors.BLUE}TEST SUMMARY{Colors.RESET}")
    print(f"{Colors.BLUE}{'='*60}{Colors.RESET}")

    passed = sum(1 for _, result in results if result)
    total = len(results)

    for test_name, result in results:
        if result:
            print_success(f"{test_name}")
        else:
            print_error(f"{test_name}")

    print(f"\n{Colors.BLUE}Results: {passed}/{total} tests passed{Colors.RESET}")

    if passed == total:
        print(f"{Colors.GREEN}✓ ALL TESTS PASSED{Colors.RESET}\n")
        return 0
    else:
        print(f"{Colors.RED}✗ SOME TESTS FAILED{Colors.RESET}\n")
        return 1

if __name__ == "__main__":
    exit(run_all_tests())
