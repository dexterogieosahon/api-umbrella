'use strict';

require('../test_helper');

var Factory = require('factory-lady'),
    mongoose = require('mongoose');

mongoose.model('ConfigVersion', new mongoose.Schema({
  version: {
    type: Date,
    unique: true,
  },
  config: mongoose.Schema.Types.Mixed,
}, { collection: 'config_versions' }));

Factory.define('config_version', mongoose.testConnection.model('ConfigVersion'), {
  version: function(callback) {
    callback(new Date());
  },
});
