//! Dynamic Value used by the template engine.
//!
//! Mirrors Go's `text/template` data model just closely enough for the
//! templates we ship: missing-key lookups silently produce `Null`, matching
//! Go's "no value" behaviour for our templates.

use std::collections::BTreeMap;

#[derive(Clone, Debug, PartialEq)]
pub enum Value {
    Null,
    Bool(bool),
    Int(i64),
    Str(String),
    List(Vec<Value>),
    Map(BTreeMap<String, Value>),
}

impl Value {
    pub fn s<S: Into<String>>(s: S) -> Self {
        Value::Str(s.into())
    }

    pub fn list(values: Vec<Value>) -> Self {
        Value::List(values)
    }

    pub fn map(fields: impl IntoIterator<Item = (String, Value)>) -> Self {
        Value::Map(fields.into_iter().collect())
    }

    pub fn get(&self, key: &str) -> Value {
        match self {
            Value::Map(m) => m.get(key).cloned().unwrap_or(Value::Null),
            _ => Value::Null,
        }
    }

    pub fn truthy(&self) -> bool {
        match self {
            Value::Null => false,
            Value::Bool(b) => *b,
            Value::Int(i) => *i != 0,
            Value::Str(s) => !s.is_empty(),
            Value::List(v) => !v.is_empty(),
            Value::Map(m) => !m.is_empty(),
        }
    }

    pub fn as_str(&self) -> String {
        match self {
            Value::Null => String::new(),
            Value::Bool(v) => v.to_string(),
            Value::Int(v) => v.to_string(),
            Value::Str(v) => v.clone(),
            Value::List(_) | Value::Map(_) => String::new(),
        }
    }

    pub fn as_i64(&self) -> i64 {
        match self {
            Value::Int(v) => *v,
            Value::Str(v) => v.parse().unwrap_or(0),
            Value::Bool(v) => i64::from(*v),
            _ => 0,
        }
    }

    pub fn as_bool(&self) -> bool {
        match self {
            Value::Bool(v) => *v,
            _ => self.truthy(),
        }
    }
}
