const crypto = require('crypto');

function successResponse(res, data = {}, message = 'Islem basarili', statusCode = 200) {
  return res.status(statusCode).json({
    success: true,
    message,
    data,
  });
}

function errorResponse(res, message = 'Bir hata olustu', statusCode = 500, errors = null) {
  const response = {
    success: false,
    message,
  };
  if (errors) response.errors = errors;
  return res.status(statusCode).json(response);
}

function generateNumericPin(length = 6) {
  let pin = '';
  for (let i = 0; i < length; i++) {
    pin += Math.floor(Math.random() * 10).toString();
  }
  return pin;
}

function generateRandomToken(bytes = 32) {
  return crypto.randomBytes(bytes).toString('hex');
}

module.exports = {
  successResponse,
  errorResponse,
  generateNumericPin,
  generateRandomToken,
};

